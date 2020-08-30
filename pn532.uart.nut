/* 
PN532 NFC reader library, controlled over UART.  

Works with multiple readers

Copied from https://gist.github.com/zandr/fc94b1fb1a368a0143ed95cf7a7def95 
and that was copied from the original SPI version of this library: 
https://github.com/electricimp/PN532/blob/v1.0.0/pn532.class.nut


*/

#require "PrettyPrinter.class.nut:1.0.1"
#require "JSONEncoder.class.nut:2.0.0"

pp <- PrettyPrinter(null, false);
print <- pp.print.bindenv(pp);

function blobToHexString(b) {
    local s = "";
    for (local i = 0 ; i < b.len() ; i++) s += format("%02x ", b[i]);
    
    // Comment out the following line if you don't want an '0x' prefix
    s = "0x" + s;

    return s;
}


//line 1 "PN532/pn532.class.nut"
class PN532 {
    
    static version = [0, 1, 0];
        
    static FRAME_TYPE_ACK = 0x01;
    static FRAME_TYPE_APPLICATION_ERROR = 0x02;
    
    static COMMAND_GET_FIRMWARE_VERSION = 0x02;
    static COMMAND_WRITE_REGISTER = 0x08;
    static COMMAND_SAM_CONFIGURATION = 0x14;
    static COMMAND_POWER_DOWN = 0x16;
    static COMMAND_RF_CONFIGURATION = 0x32;
    static COMMAND_IN_DATA_EXCHANGE = 0x40;
    static COMMAND_IN_AUTOPOLL = 0x60;
    
    static TAG_TYPE_106_A = 0x00;
    static TAG_TYPE_212 = 0x01;
    static TAG_TYPE_424 = 0x02;
    static TAG_TYPE_106_B = 0x03;
    static TAG_TYPE_106_JEWEL = 0x04;
    static TAG_FLAG_MIFARE_FELICA = 0x10;

    static POLL_INDEFINITELY = 0xFF;
    
    static STATUS_OK = 0;
    
    static WAKEUP_TIME = 0.002;
    
    static ERROR_CONCURRENT_COMMANDS = "Could not run command, previous command not completed";
    static ERROR_TRANSMIT_FAILURE = "Message transmission failed";
    static ERROR_DEVICE_APPLICATION = "Device Application Error";
    
    _uart = null;
    _messageInTransit = null;
    _powerSaveEnabled = null;

    function constructor(uart) {
        _uart = uart;
        _uart.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS, _rx_byte.bindenv(this));
                     // 115200, 8, PARITY_NONE, 1, NO_CTSRTS
        
        // If _messageInTransit.responseCallback is set, there is currently a pending request waiting for a response.
        // _messageInTransit.cancelAckTimer is called when a request is ACKed by the PN532 to prevent the timeout routine from running.
        // Both of these are maintained by sendRequest and _irqCallback
        _messageInTransit = {
            "responseCallback" : null,
            "cancelAckTimer" : null
        };
        
        _powerSaveEnabled = false;
                
        // Give time to wake up
        imp.sleep(WAKEUP_TIME);
        wake();
        server.log(format("Buffer containted %d bytes", _uart.readstring().len()));
        init(_constructorCallback);
    }
    
    function wake() {
        local wakeBlob = blob(4);
        wakeBlob.writestring("\x55\x55\x55\x55");
        _uartSendFrame(wakeBlob);
    }

    function init(callback) {
        // Disable SAM
        local mode = 0x1;
        local timeout = 0x14;

        local dataBlob = blob(2);
        dataBlob[0] = mode; 
        // dataBlob[1] = timeout;
        
        local samFrame = makeCommandFrame(COMMAND_SAM_CONFIGURATION, dataBlob);
            sendRequest(samFrame, function(error, data) {
            imp.wakeup(0, function() {
               callback(error); 
            }.bindenv(this));
        }, true);

    };
    
    function setHardPowerDown(poweredDown, callback) {
        // Control the power going into the PN532
        if(_rstpdn_l != null) {
            _rstpdn_l.write(poweredDown ? 0 : 1);
            
            if(poweredDown) {
                imp.wakeup(0, function() {
                   callback(null); 
                }.bindenv(this));
            } else {
                // Give time to wake up
                imp.sleep(WAKEUP_TIME);
                init(callback);
            }
        } else {
            imp.wakeup(0, function() {
                callback(ERROR_NO_RSTPDN);
            }.bindenv(this));
        }
    }
    
    function enablePowerSaveMode(shouldEnable, callback) {
        _powerSaveEnabled = shouldEnable;
        if(shouldEnable) {
            // Send true as the response value because it's easier than adding a separate flow for a single-argument callback
            local responseCallback = _getPowerDownResponseCallback(true, callback);
            _sendPowerDownRequest(3, responseCallback);
        } else {
            imp.wakeup(0, function() {
                callback(null, false);
            }.bindenv(this));
        }
    }
    
    function getFirmwareVersion(callback) {
        local responseCallback = _getFirmwareVersionCallback(callback);
        local frame = makeCommandFrame(COMMAND_GET_FIRMWARE_VERSION);

        sendRequest(frame, responseCallback, true);
    }
    
    function pollNearbyTags(tagType, pollAttempts, pollPeriod, callback) {
        local dataBlob = blob(3);
        
        local pollPeriodMultiplier = math.ceil(pollPeriod / 0.15);
        
        dataBlob.writen(pollAttempts, 'b');
        dataBlob.writen(pollPeriodMultiplier, 'b');
        dataBlob.writen(tagType, 'b')

        local responseCallback = _getPollTagsCallback(callback);
        local frame = makeCommandFrame(COMMAND_IN_AUTOPOLL, dataBlob);
        sendRequest(frame, responseCallback, false);
    }
    
    static function makeDataExchangeFrame(tagNumber, data) {
        data.seek(0, 'b');
        
        local exchangeFrame = blob(1 + data.len());
        exchangeFrame.writen(tagNumber, 'b');
        exchangeFrame.writeblob(data);
        return makeCommandFrame(COMMAND_IN_DATA_EXCHANGE, exchangeFrame);
    }
    
    static function makeCommandFrame(command, data=null) {
        local dataSize = data == null ? 0 : data.len();
        local frame = blob(1 + dataSize);
        frame.writen(command, 'b');
        if(data != null) {
            frame.writeblob(data);
        }
        
        return _makeInformationFrame(frame);
    }
    
    function sendRequest(requestFrame, responseCallback, shouldRespectPowerSave, numRetries=3) {
        
        // Do not let a new message be sent if there is a currently pending one
        if(_messageInTransit.responseCallback == null) {
            
            local effectiveResponseCallback = responseCallback;
            if(_powerSaveEnabled && shouldRespectPowerSave) {
                effectiveResponseCallback = _getPowerDownSenderCallback(numRetries, responseCallback);
            }
            
            _messageInTransit.responseCallback = effectiveResponseCallback;
            _uartSendFrame(requestFrame, function(){
                local cancelAckTimer = _startAckTimer(requestFrame, effectiveResponseCallback, numRetries);
                _messageInTransit.cancelAckTimer = cancelAckTimer;
            }.bindenv(this));
            
            // _spiSendFrame(SPI_OP_DATA_WRITE, requestFrame, function(){
            //     local cancelAckTimer = _startAckTimer(requestFrame, effectiveResponseCallback, numRetries);
            //     _messageInTransit.cancelAckTimer = cancelAckTimer;
            // }.bindenv(this));
        } else {
            imp.wakeup(0, function() {
                responseCallback(ERROR_CONCURRENT_COMMANDS, null);
            }.bindenv(this));            
        }
    }
    
    // -------------------- PRIVATE METHODS -------------------- //

    function _getFirmwareVersionCallback(userCallback) {
        return function(error, version) {
            if(error != null) {
                imp.wakeup(0, function() {
                   userCallback(error, null); 
                }.bindenv(this));
                return;
            }
            
            local versionTable = {};
            versionTable["ic"] <- version[1];
            versionTable["ver"] <- version[2];
            versionTable["rev"] <- version[3];
            versionTable["support"] <- version[4];
            
            imp.wakeup(0, function() {
               userCallback(null, versionTable); 
            }.bindenv(this));
        };
    }

    function _getPollTagsCallback(userCallback) {
        return function(error, responseData) {
            if(error != null) {
                imp.wakeup(0, function() {
                   userCallback(error, null, null); 
                }.bindenv(this));
                return;
            }
            
            // Consume message type
            responseData.seek(1, 'b');
            
            local numTagsFound = responseData.readn('b');
            local tagData = null;
            
            if(numTagsFound > 0) {
                
                local tagType = responseData.readn('b');
                
                local dataLength = responseData.readn('b');
                
                // Consume the tag number (i.e. out of numTagsFound)
                responseData.readn('b');
                
                local sensRes = responseData.readblob(2);

                local selRes = responseData.readn('b');

                local nfcIdLength = responseData.readn('b');
                local nfcId = responseData.readblob(nfcIdLength);
                
                // Read ATS frame if it exists
                local atsFrame = null;
                local atsFrameExists = responseData.tell() < responseData.len();
                if(atsFrameExists) {
                    local atsFrameLength = responseData.readn('b');
                    atsFrame = responseData.readblob(atsFrameLength);
                }
                
                tagData = {
                    "type" : tagType,
                    "SENS_RES" : sensRes
                    "SEL_RES" : selRes,
                    "NFCID" : nfcId,
                    "ATS" : atsFrame
                };
            }
            
            imp.wakeup(0, function() {
               userCallback(null, numTagsFound, tagData); 
            }.bindenv(this));
        };
    }
    
    // This callback ensures that the power down command is sent after a primary command
    function _getPowerDownSenderCallback(numRetries, userCallback) {
        return function(error, response) {
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                }.bindenv(this));
                return;
            }
            
            // Save the response and run the power down command
            local callback = _getPowerDownResponseCallback(response, userCallback);
            _sendPowerDownRequest(numRetries, callback)
        };
    }
    
    // This callback ensures that the response from the primary command is sent to the original user callback
    function _getPowerDownResponseCallback(primaryCommandResponse, userCallback) {
        return function(error, response) {
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                }.bindenv(this));
                return;
            }
            
            // Read application-level status to ensure power-down was successful
            local status = response[1];
            if(status != STATUS_OK) {
                imp.wakeup(0, function() {
                    userCallback("Power-down error: " + status, primaryCommandResponse);
                }.bindenv(this));
                return;
            }
            
            // PN532 takes 1ms to go into power down mode
            imp.sleep(0.001);
            
            imp.wakeup(0, function() {
                // Finally, send the user the response we've been holding onto
                userCallback(null, primaryCommandResponse);
            }.bindenv(this));
        };
    }

    /***** APPLICATION LAYER COMMUNICATION *****/
    
    function _sendPowerDownRequest(numRetries, responseCallback) {
        local wakeupEnable = 32; // Only enable wakeup on SPI signal
        
        local dataBlob = blob(1);
        dataBlob.writen(wakeupEnable, 'b');
        
        local frame = makeCommandFrame(COMMAND_POWER_DOWN, dataBlob);
        sendRequest(frame, responseCallback, false, numRetries);
    }

    // Encapsulates the payload blob in an information frame
    static function _makeInformationFrame(payload) {
        local AMBLE = 0x00; // Preamble and postamble code
        local START_CODE = 0xFF00; // Intentionally backwards
        local TFI = 0xD4;

        // Construct [ TFI || payload ] first for easy checksum calculation 
        local taggedPayloadLength = payload.len() + 1;
        payload.seek(0);
        local taggedPayload = blob(taggedPayloadLength);
        taggedPayload.writen(TFI, 'b');
        taggedPayload.writeblob(payload);
        
        // Construct frame: [ PREAMBLE || STARTCODE || len || lcs || TFI || payload || dcs || POSTAMBLE ]
        local frame = blob(7 + taggedPayloadLength);
        frame.writen(AMBLE, 'b');
        frame.writen(START_CODE, 'w');
        frame.writen(taggedPayloadLength, 'b');
        frame.writen(_computeChecksumByte(taggedPayloadLength), 'b');
        frame.writeblob(taggedPayload);
        frame.writen(_computeChecksumBlob(taggedPayload), 'b');
        frame.writen(AMBLE, 'b');
        
        return frame;
    }
    
    // Computes a checksum such that lower byte of [data + checksum] = 0x00
    static function _computeChecksumByte(data) {
        return (0 - data) & 0xff;
    }
    
    // Computes a checksum like in _computeChecksumByte, except across the sum of an entire data blob
    static function _computeChecksumBlob(data) {
        local sum = 0;
        foreach(byte in data) {
            sum += byte;
        }
        return _computeChecksumByte(sum);
    }
    
    static function _makeNackFrame() {
        local frame = blob(6);
        frame.writestring("\0\0\xff\xff\0\0");
        return frame;
    }
    
    /***** LINK LAYER COMMUNICATION *****/
    
    function _spiSendFrame(spiOp, frame, callback=null) {
        frame.seek(0, 'b');
        
        // Wake up the PN532 and give it time to set up
        _ncs.write(0);
        imp.sleep(WAKEUP_TIME);
        
        _spi.write(format("%c", spiOp));
        _spi.write(frame);
        
        // Put the PN532 back to sleep
        _ncs.write(1);
        
        if(callback != null) {
            // Run callback immediately so we can act before a quick response gets in
            callback();
        }
    }

    function _uartSendFrame(frame, callback=null) {
        // server.log("_uartSendFrame: " + blobToHexString(frame));
        frame.seek(0, 'b');

        _uart.write(frame);
        if(callback != null) {
            callback();
        }
    
    }
    
    // TODO: parse extended frame format
    function _parseReceivedFrame(frame) {
        local VALID_FRAME_BEGIN = "\0\xff";
        local PACKET_CODE_ACK = "\0\xff";
        local TFI_INCOMING = 0xD5;
        local TFI_APPLICATION_ERROR = 0x7F;

        local parsedFrame = {
            "type" : null,
            "data" : null,
            "error" : null
        };

        // Consume the beginning of the frame to check for errors and establish frame length.

        if(frame.find(VALID_FRAME_BEGIN) != 0) {
            parsedFrame.error = true; // Invalid frame
        } else {
            if(frame.find(PACKET_CODE_ACK, 2) == 2) {
                parsedFrame.type = FRAME_TYPE_ACK;
            } else {
                local packetLength = frame[2];
                local packetLengthChecksum = frame[3];
                // server.log("ZM: LenCS:" +packetLengthChecksum);
                if(_computeChecksumByte(packetLength) != packetLengthChecksum) {
                    parsedFrame.error = true; // Packet length checksum failure
                    // server.log("ZM: length checksum failed")
                } else {
                    // Consume the remainder of the frame and package it for parsing
                    local frameBody = blob();
                    frameBody.writestring(frame.slice(4)); // include checksum
                    // server.log("ZM: frameBody");
                    // server.log(packetLength)
                    // server.log(blobToHexString(frameBody));
                    frameBody.seek(0, 'b');
                    if(_computeChecksumBlob(frameBody.readblob(packetLength)) != frameBody[packetLength]) {
                        parsedFrame.error = true; // Data checksum failure
                        // server.log("ZM: data checksum failed")
                    } else {
                        // server.log("ZM: parsing frameBody");
                        switch(frameBody[0]) {
                            case TFI_INCOMING:
                                frameBody.seek(1, 'b');
                                parsedFrame.data = frameBody.readblob(packetLength - 1);
                                // server.log("ZM: parsedFrame.data");
                                // server.log(blobToHexString(parsedFrame.data));
                                break;
                            case TFI_APPLICATION_ERROR:
                                parsedFrame.type = FRAME_TYPE_APPLICATION_ERROR;
                                break;
                            default:
                                parsedFrame.error = true; // Unrecognized TFI
                        }
                    }
                }
            }
        }
        
        // Put the PN532 back to sleep
        _handleFrame(parsedFrame);
    }


    function _spiReceiveFrame() {
        local VALID_FRAME_BEGIN = "\0\0\xff";
        local PACKET_CODE_ACK = "\0\xff";
        local TFI_INCOMING = 0xD5;
        local TFI_APPLICATION_ERROR = 0x7F;

        local parsedFrame = {
            "type" : null,
            "data" : null,
            "error" : null
        };

        // Wake up the PN532 and give it time to set up
        _ncs.write(0);
        imp.sleep(WAKEUP_TIME);

        // Formally request the incoming frame
        _spi.write(format("%c", SPI_OP_DATA_READ));
        
        // Consume the beginning of the frame to check for errors and establish frame length.
        local frameBeginning = _spi.readstring(5);
        
        if(frameBeginning.find(VALID_FRAME_BEGIN) != 0) {
            parsedFrame.error = true; // Invalid frame
        } else {
        
            if(frameBeginning.find(PACKET_CODE_ACK, 3) == 3) {
                parsedFrame.type = FRAME_TYPE_ACK;
            } else {
            
                local packetLength = frameBeginning[3];
                local packetLengthChecksum = frameBeginning[4];

                if(_computeChecksumByte(packetLength) != packetLengthChecksum) {
                    parsedFrame.error = true; // Packet length checksum failure
                } else {
                
                    // Consume the remainder of the frame and package it for parsing
                    local frameBody = _spi.readblob(packetLength + 1);
                    frameBody.seek(0, 'b');
                    if(_computeChecksumBlob(frameBody.readblob(packetLength)) != frameBody[packetLength]) {
                        parsedFrame.error = true; // Data checksum failure
                    } else {
                        
                        switch(frameBody[0]) {
                            case TFI_INCOMING:
                                frameBody.seek(1, 'b');
                                parsedFrame.data = frameBody.readblob(packetLength - 1);
                                break;
                            case TFI_APPLICATION_ERROR:
                                parsedFrame.type = FRAME_TYPE_APPLICATION_ERROR;
                                break;
                            default:
                                parsedFrame.error = true; // Unrecognized TFI
                        }
                    }
                }
            }
        }
        
        // Put the PN532 back to sleep
        _ncs.write(1);
        return parsedFrame;
    }
    
    _rxpacket = null;
    _rxstate = 0;
    _rxlen = 0;

    function _rx_byte() {
        local d = _uart.read();        
        if (_rxpacket) { _rxpacket[_rxstate] = d };

        switch(_rxstate) {
            case 0: //wait for 00
                if (d == 0x00) {
                    _rxpacket = blob(256);
                    _rxpacket[0] = 0x00;
                    _rxstate++;
                }
                break;
            case 1: // wait for subsequent FF, which should be a packet start
                if (d == 0xFF) _rxstate++;
                else if (d != 0x00) _rxstate = 0;
                break;
            case 2: // Packet Length
                _rxlen = d;
                _rxstate++;
                break;
            default:
                if (++_rxstate == (4 + _rxlen + 1)) {
                    //Got the whole thing, parse it
                    _parseReceivedFrame(_rxpacket.tostring());
                    //Reset state machine and free the packet buffer.
                    _rxstate = _rxlen = 0;
                    _rxpacket = null;
                }
                break;
        }
    }

    function _handleFrame(parsedFrame) {
        if(parsedFrame.error) {
            local nackFrame = _makeNackFrame();
            _uartSendFrame(nackFrame);
            server.log("ZM: NACK.")
            return;
        }
        
        if(parsedFrame.type == FRAME_TYPE_ACK) {
            _messageInTransit.cancelAckTimer();
        } else if(parsedFrame.type == FRAME_TYPE_APPLICATION_ERROR) {
            parsedFrame.error = ERROR_DEVICE_APPLICATION;
        } else if(_messageInTransit.responseCallback != null) {
            // If there is a callback, run and clear it
            local savedResponseCallback = _messageInTransit.responseCallback;
            _messageInTransit.responseCallback = null;
            savedResponseCallback(parsedFrame.error, parsedFrame.data);
        }
    }
    
    function _startAckTimer(requestFrame, responseCallback, numRetries) {
        local timeout = 1;
        
        local timer = imp.wakeup(timeout, function() {
            // clear old callback and retry if it's worthwhile
            _messageInTransit.responseCallback = null;
            if(numRetries > 0) {
                sendRequest(requestFrame, responseCallback, true, numRetries - 1);
            } else {
                imp.wakeup(0, function() {
                    responseCallback(ERROR_TRANSMIT_FAILURE, null);
                }.bindenv(this));
            }
        }.bindenv(this));
        
        local cancelTimer = function() {
            imp.cancelwakeup(timer);
        };
        
        return cancelTimer;
    }

    function _constructorCallback(error) {
        if(error != null) {
            server.log("Error constructing PN532: " + error);
            return;
        }
        // It's now safe to use the PN532
        getFirmwareVersion(_firmwareVersionCallback);
    }

    function _firmwareVersionCallback(error, version) {
        if (error) {
            server.log(error);
        } else {
            server.log(format("Firmware version: %X:%X.%X-%X", version.ic, version.ver, version.rev, version.support));
            
            // Working; now start polling for tags
            pollNearbyTags(PN532.TAG_TYPE_106_A | PN532.TAG_FLAG_MIFARE_FELICA, 10, 0.5, _scanCallback);
        }    
    }

    function _scanCallback(error, numTagsFound, tagData) {
        if(error != null) {
            server.log(error);
            return;
        }

        if(numTagsFound > 0) {
            // risingBeep();
            server.log("Found a tag:");
            server.log(format("SENS_RES: %X %X", tagData.SENS_RES[0], tagData.SENS_RES[1]));
            server.log("NFCID:");
            server.log(tagData.NFCID);
        } else {
            server.log("No tags found");
        }
        
        imp.wakeup(1, function() {
            pollNearbyTags(PN532.TAG_TYPE_106_A | PN532.TAG_FLAG_MIFARE_FELICA, 10, 0.5, _scanCallback);
        }.bindenv(this));
    }

    function _rxCallback() {
        server.log("Got Bits!");
        server.log(uart.read());
    }

}

local uart = hardware.uartABCD;
reader <- PN532(uart);

reader <- PN532(hardware.uartPQRS);

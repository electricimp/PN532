// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class PN532 {
    
    static version = [1, 0, 0];
    
    static SPI_OP_DATA_WRITE = 0x01;
    static SPI_OP_STATUS_READ = 0x02;
    static SPI_OP_DATA_READ = 0x03;
    
    static FRAME_TYPE_ACK = 0x01;
    static FRAME_TYPE_APPLICATION_ERROR = 0x02;
    
    static COMMAND_GET_FIRMWARE_VERSION = 0x02;
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
    
    static STATUS_OK = 0;
    
    static WAKEUP_TIME = 0.002;
    
    static ERROR_NO_RSTPDN = "No RSTPDN_l pin given";
    static ERROR_CONCURRENT_COMMANDS = "Could not run command, previous command not completed";
    static ERROR_TRANSMIT_FAILURE = "Message transmission failed";
    static ERROR_DEVICE_APPLICATION = "Device Application Error";
    
    _spi = null;
    _ncs = null; // Not Chip Select
    _rstpdn_l = null; // Reset and Power-Down, active low
    _irq = null;
    _messageInTransit = null;
    _powerSaveEnabled = null;

    function constructor(spi, ncs, rstpdn_l, irq, callback) {
        _spi = spi;
        
        _ncs = ncs;
        _ncs.configure(DIGITAL_OUT, 1); // Start high - no transmit
        
        _irq = irq
        _irq.configure(DIGITAL_IN, _irqCallback.bindenv(this));
        
        // If _messageInTransit.responseCallback is set, there is currently a pending request waiting for a response.
        // _messageInTransit.cancelAckTimer is called when a request is ACKed by the PN532 to prevent the timeout routine from running.
        // Both of these are maintained by sendRequest and _irqCallback
        _messageInTransit = {
            "responseCallback" : null,
            "cancelAckTimer" : null
        };
        
        _powerSaveEnabled = false;
        
        _rstpdn_l = rstpdn_l;
        if(_rstpdn_l != null) {
            _rstpdn_l.configure(DIGITAL_OUT, 1); // Start high - powered up
        }
        
        // Give time to wake up
        imp.sleep(WAKEUP_TIME);
        
        init(callback);
    }
    
    function init(callback) {
        // Disable SAM
        local mode = 0x1;
        local timeout = 0x14;

        local dataBlob = blob(2);
        dataBlob[0] = mode;
        dataBlob[1] = timeout;
        
        local samFrame = makeCommandFrame(COMMAND_SAM_CONFIGURATION, dataBlob);
        sendRequest(samFrame, function(error, data) {
            imp.wakeup(0, function() {
               callback(error); 
            });
        }, true);
    };
    
    function setHardPowerDown(poweredDown, callback) {
        // Control the power going into the PN532
        if(_rstpdn_l != null) {
            _rstpdn_l.write(poweredDown ? 0 : 1);
            
            if(poweredDown) {
                imp.wakeup(0, function() {
                   callback(null); 
                });
            } else {
                // Give time to wake up
                imp.sleep(WAKEUP_TIME);
                init(callback);
            }
        } else {
            imp.wakeup(0, function() {
                callback(ERROR_NO_RSTPDN);
            });
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
            });
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
            _spiSendFrame(SPI_OP_DATA_WRITE, requestFrame, function(){
                local cancelAckTimer = _startAckTimer(requestFrame, effectiveResponseCallback, numRetries);
                _messageInTransit.cancelAckTimer = cancelAckTimer;
            }.bindenv(this));
        } else {
            imp.wakeup(0, function() {
                responseCallback(ERROR_CONCURRENT_COMMANDS, null);
            });            
        }
    }
    
    // -------------------- PRIVATE METHODS -------------------- //

    function _getFirmwareVersionCallback(userCallback) {
        return function(error, version) {
            if(error != null) {
                imp.wakeup(0, function() {
                   userCallback(error, null); 
                });
                return;
            }
            
            local versionTable = {};
            versionTable["ic"] <- version[1];
            versionTable["ver"] <- version[2];
            versionTable["rev"] <- version[3];
            versionTable["support"] <- version[4];
            
            imp.wakeup(0, function() {
               userCallback(null, versionTable); 
            });
        };
    }

    function _getPollTagsCallback(userCallback) {
        return function(error, responseData) {
            if(error != null) {
                imp.wakeup(0, function() {
                   userCallback(error, null, null); 
                });
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
            });
        };
    }
    
    // This callback ensures that the power down command is sent after a primary command
    function _getPowerDownSenderCallback(numRetries, userCallback) {
        return function(error, response) {
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                });
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
                });
                return;
            }
            
            // Read application-level status to ensure power-down was successful
            local status = response[1];
            if(status != STATUS_OK) {
                imp.wakeup(0, function() {
                    userCallback("Power-down error: " + status, primaryCommandResponse);
                });
                return;
            }
            
            // PN532 takes 1ms to go into power down mode
            imp.sleep(0.001);
            
            imp.wakeup(0, function() {
                // Finally, send the user the response we've been holding onto
                userCallback(null, primaryCommandResponse);
            });
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
    
    // TODO: parse extended frame format
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
    
    function _irqCallback() {
        // Make sure this was not an IRQ reset
        if(_irq.read() == 0) {
            local parsedFrame = _spiReceiveFrame();
            if(parsedFrame.error) {
                local nackFrame = _makeNackFrame();
                _spiSendFrame(SPI_OP_DATA_WRITE, nackFrame);
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
}

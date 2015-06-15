class PN532 {
    
    static SPI_OP_DATA_WRITE = 0x01;
    static SPI_OP_STATUS_READ = 0x02;
    static SPI_OP_DATA_READ = 0x03;
    
    static FRAME_TYPE_ACK = 0x01;
    static FRAME_TYPE_APPLICATION_ERROR = 0x02;
    
    static COMMAND_GET_FIRMWARE_VERSION = 0x02;
    static COMMAND_SAM_CONFIGURATION = 0x14;
    static COMMAND_RF_CONFIGURATION = 0x32;
    static COMMAND_IN_DATA_EXCHANGE = 0x40;
    static COMMAND_IN_LIST_PASSIVE_TARGET = 0x4A;
    
    static TAG_TYPE_106_A = 0x00;
    static TAG_TYPE_212_FELICIA = 0x01;
    static TAG_TYPE_424_FELICIA = 0x02;
    static TAG_TYPE_106_B = 0x03;
    static TAG_TYPE_106_JEWEL = 0x04;
    
    _spi = null;
    _nss = null; // Not Slave Select
    _rstpd = null; // Reset and Power-Down
    _irq = null;
    _messageInTransit = null;
    
    function constructor(spi, nss, rstpd, irq, callback) {
        _spi = spi;
        
        _nss = nss;
        _nss.configure(DIGITAL_OUT, 1); // Start high - no transmit
        
        _irq = irq
        _irq.configure(DIGITAL_IN, _irqCallback.bindenv(this));
        _messageInTransit = {
            "responseCallback" : null,
            "cancelAckTimer" : null
        };
        
        _rstpd = rstpd;
        _rstpd.configure(DIGITAL_OUT, 1); // Start high - powered up
        imp.sleep(0.1);
        
        init(callback);
    }
    
    function init(callback) {
        // Do some RF setup for later
        local configItem = 0x5; // MaxRetries
        local maxRetryATR = 0xFF; // Default
        local maxRetryPSL = 0x1; // Default
        local maxRetryPassiveActivation = 0x14;
        
        local dataBlob = blob(4);
        dataBlob[0] = configItem;
        dataBlob[1] = maxRetryATR;
        dataBlob[2] = maxRetryPSL;
        dataBlob[3] = maxRetryPassiveActivation;
    
        local rfConfigFrame = _makeCommandFrame(COMMAND_RF_CONFIGURATION, dataBlob);
        sendRequest(rfConfigFrame, function(error, data) {
            if(error != null) {
                imp.wakeup(0, function() {
                   callback(error); 
                });
            } else {
                // Disable SAM
                local mode = 0x1;
                local timeout = 0x14;

                local dataBlob = blob(2);
                dataBlob[0] = mode;
                dataBlob[1] = timeout;
                
                local samFrame = _makeCommandFrame(COMMAND_SAM_CONFIGURATION, dataBlob);
                sendRequest(samFrame, function(error, data) {
                        imp.wakeup(0, function() {
                           callback(error); 
                        });
                });
            }
        });
    };
    
    function getFirmwareVersion(callback) {
        local responseCallback = _getFirmwareVersionCallback(callback);
        local frame = _makeCommandFrame(COMMAND_GET_FIRMWARE_VERSION);

        sendRequest(frame, responseCallback);
    }
    
    function getNearbyTags(tagType, initiatorData, callback) {
        local responseCallback = _getNearbyTagsCallback(callback);
        
        local maxTags = 1; // Device only supports up to two tags, this limits the device to 1

        local initiatorDataLength = initiatorData == null ? 0 : initiatorData.len();
        local dataBlob = blob(2 + initiatorDataLength);
        dataBlob.writen(maxTags, 'b');
        dataBlob.writen(tagType, 'b');
        if(initiatorData != null) {
            dataBlob.writeblob(initiatorData);
        }
        
        local frame = _makeCommandFrame(COMMAND_IN_LIST_PASSIVE_TARGET, dataBlob);
        
        sendRequest(frame, responseCallback);
    }
    
    static function makeDataExchangeFrame(tagNumber, data) {
        data.seek(0, 'b');
        
        local exchangeFrame = blob(1 + data.len());
        exchangeFrame.writen(tagNumber, 'b');
        exchangeFrame.writeblob(data);
        return _makeCommandFrame(COMMAND_IN_DATA_EXCHANGE, exchangeFrame);
    }
    
    function sendRequest(requestFrame, responseCallback, numRetries=5) {
        if(_messageInTransit.responseCallback == null) {
            _messageInTransit.responseCallback = responseCallback;
            _spiSendFrame(SPI_OP_DATA_WRITE, requestFrame, function(){
                local cancelAckTimer = _startAckTimer(requestFrame, responseCallback, numRetries);
                _messageInTransit.cancelAckTimer = cancelAckTimer;
            }.bindenv(this));
        } else {
            imp.wakeup(0, function() {
                responseCallback("Could not run command, previous command not completed.", null);
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

    function _getNearbyTagsCallback(userCallback) {
        return function(error, responseData) {
            if(error != null) {
                imp.wakeup(0, function() {
                   userCallback(error, null); 
                });
                return;
            }
            
            responseData.seek(1, 'b');
            
            local numTagsFound = responseData.readn('b');
            local tagData = null;
            
            if(numTagsFound > 0) {
                
                // Skip reading the first byte, it's the tag number (i.e. out of numTagsFound)
                responseData.seek(1, 'c');
                
                local sensRes = responseData.readblob(2);

                local selRes = responseData.readn('b');

                local nfcIdLength = responseData.readn('b');
                local nfcId = responseData.readblob(nfcIdLength);
                
                // Read ATS frame if it exists
                local atsFrame = null;
                local atsFrameExists = responseData.tell() < responseData.len();
                if(atsFrameExists) {
                    local atsFrameLength = responseData.readn('b');
                    server.log("ATS FRAME LENGTH: " + atsFrameLength);
                    atsFrame = responseData.readblob(atsFrameLength);
                }
                
                tagData = {
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

    /***** APPLICATION LAYER COMMUNICATION *****/

    static function _makeCommandFrame(command, data=null) {
        local dataSize = data == null ? 0 : data.len();
        local frame = blob(1 + dataSize);
        frame.writen(command, 'b');
        if(data != null) {
            frame.writeblob(data);
        }
        
        return _makeInformationFrame(frame);
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
    
    // Computes a length checksum such that lower byte of [data + checksum] = 0x00
    static function _computeChecksumByte(data) {
        return (0 - data) & 0xff;
    }
    
    static function _computeChecksumBlob(data) {
        local sum = 0;
        foreach(byte in data) {
            sum += byte;
        }
        return _computeChecksumByte(sum);
    }
    
    static function _makeNackFrame() {
        return "\0\0\xff\xff\0\0";
    }
    
    /***** LINK LAYER COMMUNICATION *****/
    
    function _spiSendFrame(spiOp, frame, callback=null) {
        frame.seek(0, 'b');
        _nss.write(0);
        imp.sleep(0.002); // Give the PN532 time to wake up
        
        _spi.write(format("%c", spiOp));
        _spi.write(frame);
        
        _nss.write(1);
        
        if(callback != null) {
            // Run callback immediately so we can act before a quick response gets in
            callback();
        }
    }
    
    // TODO: parse extended frame format
    // TODO: add parsedFrame type for standard data frames
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

        _nss.write(0);
        imp.sleep(0.002); // Give the PN532 time to wake up

        _spi.write(format("%c", SPI_OP_DATA_READ));
        
        // Consume the beginning of the frame to check for errors and establish frame length.
        local frameBeginning = _spi.readstring(5);
        
        if(frameBeginning.slice(0, 3) != VALID_FRAME_BEGIN) {
            parsedFrame.error = "Invalid frame";
        } else {
        
            if(frameBeginning.slice(3, 5) == PACKET_CODE_ACK) {
                parsedFrame.type = FRAME_TYPE_ACK;
            } else {
            
                local packetLength = frameBeginning[3];
                local packetLengthChecksum = frameBeginning[4];

                if(_computeChecksumByte(packetLength) != packetLengthChecksum) {
                    parsedFrame.error = "Packet length checksum failure";
                } else {
                
                    // Consume the remainder of the frame
                    local frameBody = _spi.readblob(packetLength + 1);
                    frameBody.seek(0, 'b');
                    if(_computeChecksumBlob(frameBody.readblob(packetLength)) != frameBody[packetLength]) {
                        parsedFrame.error = "Data checksum failure";
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
                                parsedFrame.error = "Unrecognized TFI";
                        }
                    }
                }
            }
        }
            
        _nss.write(1);
        return parsedFrame;
    }
    
    function _irqCallback() {
        if(_irq.read() == 0) {
            local parsedFrame = _spiReceiveFrame();
            if(parsedFrame.error != null) {
                server.log("Error: " + parsedFrame.error);
                server.log("Sending NACK");
                local nackFrame = _makeNackFrame();
                _spiSendFrame(SPI_OP_DATA_WRITE, nackFrame);
                return;
            }
            
            if(parsedFrame.type == FRAME_TYPE_ACK) {
                    _messageInTransit.cancelAckTimer();
            } else {
                if(parsedFrame.type == FRAME_TYPE_APPLICATION_ERROR) {
                    parsedFrame.error = "Device Application Error";
                }
                if(_messageInTransit.responseCallback != null) {
                    local savedResponseCallback = _messageInTransit.responseCallback;
                    _messageInTransit.responseCallback = null;
                    savedResponseCallback(parsedFrame.error, parsedFrame.data);
                }
            }
        }
    }
    
    function _startAckTimer(requestFrame, responseCallback, numRetries) {
        local timeout = 1;
        
        local timer = imp.wakeup(timeout, function() {
            // clear old callback and retry if it's worthwhile
            _messageInTransit.responseCallback = null;
            if(numRetries > 0) {
                sendRequest(requestFrame, responseCallback, numRetries - 1);
            }
        }.bindenv(this));
        
        local cancelTimer = function() {
            imp.cancelwakeup(timer);
        };
        
        return cancelTimer;
    }
}

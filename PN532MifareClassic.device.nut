// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class PN532MifareClassic {
    static CMD_AUTH_A = 0x60;
    static CMD_AUTH_B = 0x61;
    static CMD_READ_16 = 0x30;
    static CMD_WRITE_16 = 0xA0;
    
    static AUTH_TYPE_A = "A";
    static AUTH_TYPE_B = "B";

    static AUTH_ERROR = 0x14;

    static BLOCK_LENGTH = 16;
    
    static ERROR_INCORRECT_LENGTH = "Incorrect data length (must be 16 bytes)";
    static ERROR_BAD_AUTHENTICATION = "Bad authentication";
    
    _pn532 = null;
    
    function constructor(pn532) {
        _pn532 = pn532;
    }
    
    function pollNearbyTags(pollAttempts, pollPeriod, callback) {
        _pn532.pollNearbyTags(PN532.TAG_TYPE_106_A | PN532.TAG_FLAG_MIFARE_FELICA, pollAttempts, pollPeriod, callback);
    }
    
    function authenticate(tagSerial, address, aOrB, key, callback){
        if(key == null) {
            key = _getDefaultKey();
        }
        
        // Choose to authenticate with the A or B key
        local cmd = aOrB == AUTH_TYPE_A ? CMD_AUTH_A : CMD_AUTH_B;
        
        // Tag serials tend to be either 4 or 7 bytes
        local payload = blob(6 + tagSerial.len());
        
        payload.writeblob(key);
        payload.writeblob(tagSerial);
        
        // Package and send request
        local responseCallback = _getAuthenticationCallback(callback);
        local frame = _makeMifareFrame(cmd, address, payload);
        _pn532.sendRequest(frame, responseCallback.bindenv(this), false);
    }
    
    function read(address, callback) {
        local responseCallback = _getReadCallback(callback);
        local frame = _makeMifareFrame(CMD_READ_16, address);
        _pn532.sendRequest(frame, responseCallback.bindenv(this), false);        
    }
    
    function write(address, data, callback) {
        // Each block has 16 bytes to write to
        if(data.len() != BLOCK_LENGTH) {
            imp.wakeup(0, function() {
                callback(ERROR_INCORRECT_LENGTH, null);
            });
        }
        
        // Package and send request
        local responseCallback = _getStatusOkCallback(callback);
        local frame = _makeMifareFrame(CMD_WRITE_16, address, data);
        _pn532.sendRequest(frame, responseCallback.bindenv(this), false);      
    }
    
    // -------------------- PRIVATE METHODS -------------------- //
    
    static function _makeMifareFrame(command, address, data=null) {
        local dataLength = data == null ? 0 : data.len();
        local frame = blob(2 + dataLength);
        
        frame.writen(command, 'b');
        frame.writen(address, 'b');
        
        // Optionally add extra data (e.g. write payload)
        if(data != null) {
            data.seek(0, 'b');
            frame.writeblob(data);
        }
        
        // Use the base PN532 class to make the proper frame
        // We only support communicating with one tag at a time, so target tag 1
        return PN532.makeDataExchangeFrame(1, frame);
    }
    
    static function _getAuthenticationCallback(userCallback) {
        return function(error, responseData) {
            
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                });
                return;
            }
            
            // Consume response type byte
            responseData.readn('b');
            
            local status = responseData.readn('b');
            if(status == PN532.STATUS_OK) {
                imp.wakeup(0, function() {
                    userCallback(null, true);
                });
            } else {
                local message = status == AUTH_ERROR ? ERROR_BAD_AUTHENTICATION : "Error: " + status;
                imp.wakeup(0, function() {
                    userCallback(message, null);
                });
            }
        };
    }
    
    static function _getReadCallback(userCallback) {
        return function(error, responseData) {
            
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                });
                return;
            }
            
            // Consume response type byte
            responseData.readn('b');
            
            local status = responseData.readn('b');
            if(status == PN532.STATUS_OK) {
                local readData = responseData.readblob(BLOCK_LENGTH); // DataIn has max length of 16
                imp.wakeup(0, function() {
                    userCallback(null, readData);
                });
            } else {
                imp.wakeup(0, function() {
                    userCallback("Read error: " + status, null);
                });
            } 
        };
    }
    
    // A misc. callback that just checks the status bit and handles errors.
    // Useful for requests that have no data in the response to return to the user.
    static function _getStatusOkCallback(userCallback) {
        return function(error, responseData) {
            
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null);
                });
                return;
            }
            
            // Consume response type byte
            responseData.readn('b');
            
            local status = responseData.readn('b');
            if(status == PN532.STATUS_OK) {
                imp.wakeup(0, function() {
                    userCallback(null);
                });                
            } else {
                imp.wakeup(0, function() {
                    userCallback("Error: " + status);
                });
            }
        };
    }
    
    // Returns a blob with value FFFFFFFFFFFFh.
    // This value is set at manufacturing as the key for all blocks but can be changed later.
    static function _getDefaultKey() {
        local key = blob(6);
        key.writen(0xFFFFFFFF, 'i');
        key.writen(0xFFFF, 'w');
        
        return key;
    }
}

// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class PN532CardEmulator {
    static COMMAND_INIT_AS_TARGET = 0x8C;
    
    static BAUD_TABLE = [106, 212, 424];
    
    _pn532 = null;
    
    function constructor(pn532) {
        _pn532 = pn532;
    }
    
    function enterTargetMode(mifareParams, felicaParams, nfcId3t, generalBody, onSelect) {
        // Set no restriction on who can target us
        local mode = 0;
        
        // Construct payload
        local generalBodyLength = generalBody == null ? 0 : generalBody.len();
        
        local basePayloadLength = 26;
        local dataBlob = blob(basePayloadLength + generalBodyLength);
        dataBlob.writen(mode, 'b');
        dataBlob.writeblob(mifareParams);
        dataBlob.writeblob(felicaParams);
        dataBlob.writeblob(nfcId3t);
        dataBlob.writen(generalBodyLength, 'b');
        if(generalBody != null) {
            dataBlob.writeblob(generalBody);
        }
        // Send no historical bytes
        dataBlob.writen(0, 'b');
        
        local responseCallback = _getInitCallback(onSelect);
        local frame = PN532.makeCommandFrame(COMMAND_INIT_AS_TARGET, dataBlob);
        _pn532.sendRequest(frame, responseCallback.bindenv(this), true);
    }
    
    // Convenience method to package required data in an array
    static function makeMifareParams(sensRes, nfcId1t, selRes) {
        local params = blob(6);
        params.writen(sensRes, 'w');
        params.writeblob(nfcId1t);
        params.writen(selRes, 'b');
        return params;
    }

    // Convenience method to package required data in an array
    static function makeFelicaParams(nfcId2t, pad, systemCode) {
        local params = blob(18);
        params.writeblob(nfcId2t);
        params.writeblob(pad);
        params.writen(systemCode, 'w');
        return params;
    }
    
    // -------------------- PRIVATE METHODS -------------------- //
    
    function _getInitCallback(userCallback) {
        return function(error, response) {
            if(error != null) {
                imp.wakeup(0, function() {
                    userCallback(error, null, null);
                });
                return;
            }
            
            // Consume response code
            response.readn('b');
            
            // Parse mode byte
            local modeByte = response.readn('b');
            
            local baudMask = 0x70;
            local piccMask = 0x08;
            local depMask = 0x04;
            local frameTypeMask = 0x03;
            
            local modeTable = {
                "baud" : BAUD_TABLE[modeByte & baudMask],
                "isPicc" : (modeByte & baudMask) == baudMask,
                "isDep" : (modeByte & depMask) == depMask,
                "isActive" : (modeByte & frameTypeMask) == 1
            }
            
            // The initiator command has a different format per protocol, so we can't parse out the length
            local initiatorCommandLength = response.len() - response.tell();
            local initiatorCommand = response.readblob(initiatorCommandLength);
            
            imp.wakeup(0, function() {
                userCallback(null, modeTable, initiatorCommand);
            });
        };
    }
}

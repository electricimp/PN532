#require "PN532.class.nut:1.0.0"
#require "PN532MifareClassic.class.nut:1.0.0"

const USER_ID_ADDRESS = 0x02;

// Label all pins
local spi = hardware.spi257;
local ncs = hardware.pin1;
local rstpd_l = hardware.pin3;
local irq = hardware.pin4;

// Pre-configure SPI bus
spi.configure(LSB_FIRST | CLOCK_IDLE_HIGH, 2000);

// Returns whether this is a MIFARE Classic 1k tag
// A base list of identifiers can be found at http://nfc-tools.org/index.php?title=ISO14443A
function isMifareClassic1k(tagData) {
    return tagData.SENS_RES[0] == 0x00 && tagData.SENS_RES[1] == 0x04 && tagData.SEL_RES == 0x08;
}

function pollCallback(error, numTagsFound, tagData) {
    if(error != null) {
        server.error(error);
        return;
    }
        
    if(numTagsFound > 0 && isMifareClassic1k(tagData)) {
        mifareReader.authenticate(tagData.NFCID, USER_ID_ADDRESS, PN532MifareClassic.AUTH_TYPE_A, null, function(error, authenticated) {
            if(error != null) {
                server.error(error);
                return;
            }
            
            if(authenticated) {
                mifareReader.read(USER_ID_ADDRESS, function(error, data) {
                    if(error != null) {
                        server.error(error);
                        return;
                    }
                    
                    server.log("Found tag with user ID: ")
                    server.log(data);
                    
                    // Repeat for next tag in a second
                    imp.wakeup(1, function() {
    	                mifareReader.pollNearbyTags(PN532.POLL_INDEFINITELY, 6, pollCallback);
                    });
                });
            }  else {
                // Repeat for next tag in a second
                imp.wakeup(1, function() {
	                mifareReader.pollNearbyTags(PN532.POLL_INDEFINITELY, 6, pollCallback);
                });
            }
        });
    } else {
        // Repeat for next tag in a second
        imp.wakeup(1, function() {
            mifareReader.pollNearbyTags(PN532.POLL_INDEFINITELY, 6, pollCallback);
        });
    }
};

reader <- PN532(spi, ncs, rstpd_l, irq, function(error) {
    if(error != null) {
        server.error("Error constructing PN532: " + error);
        return;
    }

    // It's now safe to use the PN532

    reader.enablePowerSaveMode(true, function(error, success) {
        if(error != null) {
            server.error(error);
            return;
        }
        
        // Add in MIFARE functionality
        mifareReader <- PN532MifareClassic(reader);

        // Begin scanning for cards - around once a second, indefinitely
        server.log("Beginning ID poll");
	    mifareReader.pollNearbyTags(PN532.POLL_INDEFINITELY, 1.0, pollCallback); 
    });
});

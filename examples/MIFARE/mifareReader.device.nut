#require "PN532.class.nut:1.0.0"
#require "PN532MifareClassic.class.nut:1.0.0"

static USER_ID_ADDRESS = 0x02;

// Label all pins
local spi = hardware.spi257;
local ncs = hardware.pin1;
local rstpd = hardware.pin3;
local irq = hardware.pin4;

// Pre-configure SPI bus
spi.configure(LSB_FIRST | CLOCK_IDLE_HIGH, 2000);

function pollCallback(error, numTagsFound, tagData) {
    if(error != null) {
        server.log(error);
        return;
    }

    // Since we are polling indefinitely, this should only have been called if a tag was found or if the poll was interrupted
    if(numTagsFound > 0) {

    	// Assume that the card is a MIFARE classic and attempt to authenticate a block
        mifareReader.authenticate(tagData.NFCID, USER_ID_ADDRESS, PN532MifareClassic.AUTH_TYPE_A, null, function(error, authenticated) {
            if(error != null) {
                server.log(error);
                return;
            }
            
            if(authenticated) {

            	// Read a block where we previously put a user ID
                mifareReader.read(USER_ID_ADDRESS, function(error, data) {
                    if(error != null) {
                        server.log(error);
                        return;
                    }
                    
                    server.log("Found tag with user ID: ")
                    server.log(data);
                    
                    // Repeat for next tag in a second
                    imp.wakeup(1, function() {
    	                mifareReader.pollNearbyTags(0xFF, 6, pollCallback);
                    });
                });
            }  else {
                // Repeat for next tag in a second
                imp.wakeup(1, function() {
	                mifareReader.pollNearbyTags(0xFF, 6, pollCallback);
                });
            }
        });
    }
};

reader <- PN532(spi, ncs, rstpd, irq, function(error) {
    if(error != null) {
        server.log("Error constructing PN532: " + error);
        return;
    }

    // It's now safe to use the PN532

    reader.enablePowerSaveMode(true, function(error, success) {
        if(error != null) {
            server.log(error);
            return;
        }
        
        // Add in MIFARE functionality
        mifareReader <- PN532MifareClassic(reader);

        // Begin scanning for cards - around once a second, indefinitely
        server.log("Beginning ID poll");
	    mifareReader.pollNearbyTags(0xFF, 6, pollCallback); 
    });
});

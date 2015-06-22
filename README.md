# PN532 NFC Library

This library allows for integration of NXP's [PN532/C106 NFC Module](http://www.nxp.com/documents/short_data_sheet/PN532_SDS.pdf) in an Electric Imp project.  This device supports a wide range of NFC technologies, including read, write, and emulation support for MIFARE, FeliCa, and ISO/IEC 14443A tags.  It also supports peer-to-peer communication and has power-saving options.

This library currently contains three classes:

- The [`PN532`](#pn532-class) class contains the base code needed to initialize the PN532, communicate with it, read from generic NFC tags, and enable power-saving features.
- The [`PN532MifareClassic`](#pn532-mifare-classic-class) class contains functions needed to read and write to [MIFARE Classic](http://www.nxp.com/products/identification_and_security/smart_card_ics/mifare_smart_card_ics/mifare_classic/) tags, which support read/write storage.  It also serves as an example of how to build on the `PN532` class to interface with the many other protocols and features that the PN532 supports.
- The [`PN532CardEmulator`](#pn532-card-emulator-class) class contains functions needed to operate in a generic card emulation mode.  It also serves as an example of how to build on the `PN532` class to interface with the many other protocols and features that the PN532 supports.

### Examples

For an example of using the `PN532MifareClassic` class to build an ID card reader, see the [MIFARE reader example](examples/MIFARE).

# PN532 Class

## Constructor: PN532(*spi, ncs, rstpd, irq, callback*)

Creates and initializes an object representing the PN532 NFC device.

### Parameters

- *spi*: A [SPI object](https://electricimp.com/docs/api/hardware/spi/) pre-configured with the flags `LSB_FIRST | CLOCK_IDLE_HIGH` and a clock rate.  The PN532 supports clock rates up to 5 MHz.
- *ncs*: A pin connected to the PN532's not-chip-select line.
- *rstpd*: A pin connected to the PN532's RSTPDN (Reset/Power-Down) pin.  This can be null if this the RSTPDN pin will not be under software control.
- *irq*: A pin connected to the PN532's P70_IRQ pin.
- *callback*: A function that will be called when object instantiation is complete.  It takes one *error* parameter that is null upon successful instantiation.

### Usage

```squirrel
#require "PN532.class.nut:1.0.0"

local spi = hardware.spi257;
local ncs = hardware.pin1;
local rstpd = hardware.pin3;
local irq = hardware.pin4;

spi.configure(LSB_FIRST | CLOCK_IDLE_HIGH, 2000);

function constructorCallback(error) {
    if(error != null) {
        server.log("Error constructing PN532: " + error);
        return;
    }
    // It's now safe to use the PN532
}

reader <- PN532(spi, ncs, rstpd, irq, constructorCallback);
```

## init(*callback*)

Configures the PN532 with settings for later use.  The *callback* is called upon completion and takes one *error* parameter that is null on success.

This method must be called whenever the PN532 is power-cycled, but is automatically called by the constructor.

### Usage

```squirrel
function initCallback(error) {
    if(error != null) {
        server.log("Error re-initializing PN532: " + error);
        return;
    }
    // It's now safe to use the PN532
}

// Power cycle the device
rstpd.write(0);
rstpd.write(1);

// Reinitialize
reader.init(initCallback);
```

## setHardPowerDown(*poweredDown, callback*)

Enables or disables power to the PN532 using the *rstpdn* pin passed to the constructor.

This produces a greater power savings than using [enablePowerSaveMode(*shouldEnable [, callback]*)](#enablepowersavemodeshouldenable--callback), but wipes all device state and must be explicitly turned off before the PN532 can be used again.  It will automatically call [init(*callback*)](#initcallback) upon power-up.

The *callback* is called upon completion and takes one *error* parameter that is null on success.

If the *rstpdn* pin was not passed to the constructor, the callback will return an error.

### Usage

```squirrel
reader.setHardPowerDown(true, function(error) {
    if(error != null) {
        server.log(error);
        return;
    }
    
    // Spend a long time doing things that don't require the PN532...
    
    reader.setHardPowerDown(false, function(error) {
        if(error != null) {
            server.log(error);
            return;
        }
        
        // Continue using the PN532 from here
    });

});
```

## enablePowerSaveMode(*shouldEnable [, callback]*)

Enables or disables a power-saving mode on the PN532.  This mode will apply to all future commands on the PN532 until it is disabled with another call to this method.  Use of power-save mode will add a 1 ms latency to all commands sent, but significantly decreases power consumption.

Note that even if this is set, power save mode will not be entered after certain commands (such as [pollNearbyTags(*tagType, pollAttempts, pollPeriod, callback*)](#pollnearbytagstagtype-pollattempts-pollperiod-callback)) that require state to be stored on the PN532.  This is automatically handled by the class and power save mode will be re-entered when a compatible command is run.

When *shouldEnable* is true, *callback* must exist and take the following parameters:

- *error*: A string that is null on success.
- *wasEnabled*: A boolean that will only be true on success.

When *shouldEnable* is false, the callback is optional and will be ignored.

### Usage

```squirrel
function powerSaveCallback(error, succeeded) {
        // Continue using PN532 with lower power usage 
}

reader.enablePowerSaveMode(true, powerSaveCallback);
```

## getFirmwareVersion(*callback*)

Queries the PN532 for its internal firmware version number.

Takes a *callback* with two parameters:

- *error*: A string that is null on success.
- *version*: A table that contains fields for *IC*, *Ver*, *Rev*, and *Support* as documented in the `GetFirmwareVersion` command from the [PN532 datasheet](http://www.nxp.com/documents/user_manual/141520.pdf).

### Usage

```squirrel
function firmwareVersionCallback(error, version) {
        server.log(format("Firmware version: %X:%X.%X-%X", version, version.ver, version.rev, version.support));
}

reader.getFirmwareVersion(firmwareVersionCallback);
```

## pollNearbyTags(*tagType, pollAttempts, pollPeriod, callback*)

Repeatedly searches for nearby NFC tags of type *tagType* and passes scan results to the *callback* upon completion.

### Parameters

- *tagType*: An integer representing the baud rate and initialization protocol used during the scan.  It must be taken from the following static class members:

 - `PN532.TAG_TYPE_106_A`: 106 kbps ISO/IEC14443 Type A
 - `PN532.TAG_TYPE_212`: Generic 212 kbps
 - `PN532.TAG_TYPE_424`: Generic 424 kbps
 - `PN532.TAG_TYPE_106_B`: 106 kbps ISO/IEC14443-3B
 - `PN532.TAG_TYPE_106_JEWEL`: 106 kbps Innovision Jewel

    Any of the above members can also be combined with the flag `PN532.TAG_FLAG_MIFARE_FELICA` where appropriate to specify that only cards with MIFARE or FeliCa support should be polled.
- *pollAttempts*: An integer representing how many times the PN532 should search for the specified card type. Any value between 0x01 and 0xFE will initiate the corresponding number of polls.  The value 0xFF will poll forever until a card is found.
- *pollPeriod*: An integer controlling the time in between poll attempts.  It indicates units of 150 ms.
- *callback*: A function with the following parameters:
 - *error*: A string that is null on success.
 - *numTagsFounds*: The number of tags found during the scan (currently either 1 or 0)
 - *tagData*: A table that is non-null only when *numTagsFound* is 1 and contains the following fields:
     - *type*: The type of tag found.  This corresponds to the tag type specified above except when the `TAG_FLAG_MIFARE_FELICA` flag has not been used, when it will be added if MIFARE or FeliCa support has been detected.
     - *SENS_RES*: A 2-byte blob representing the SENS_RES/ATQA field of the tag
     - *SEL_RES*: 1 byte representing the SEL_RES/SAK field of the tag
     - *NFCID*: A blob representing the semi-unique UID of the tag (usually either 4 or 7 bytes)
     - *ATS*: The ATS response, if generated by the tag

### Usage

```squirrel
function scanCallback(error, numTagsFound, tagData) {
    if(error != null) {
        server.log(error);
        return;
    }
    
    if(numTagsFound > 0) {
        server.log("Found a tag:");
        server.log(format("SENS_RES: %X %X", tagData.SENS_RES[0], tagData.SENS_RES[1]));
        server.log("NFCID:");
        server.log(tagData.NFCID);
    } else {
        server.log("No tags found");
    }
}

// Poll 10 times around once a second
reader.pollNearbyTags(PN532.TAG_TYPE_106_A | PN532.TAG_FLAG_MIFARE_FELICA, 0x0A, 6, scanCallback);
```

**The following methods are exposed for use in creating extensions of the PN532 class to support extra protocols and commands.**

## PN532.makeDataExchangeFrame(*tagNumber, data*)

Constructs a data exchange frame for use in [PN532.sendRequest(*requestFrame, responseCallback, shouldRespectPowerSave [, numRetries]*)](#sendrequestrequestframe-responsecallback-shouldrespectpowersave--numretries).

### Parameters

- *tagNumber*: The index number of the tag in the current field.  Currently this is always 1.
- *data*: The payload blob for this frame.

See the [PN532 datasheet](http://www.nxp.com/documents/user_manual/141520.pdf) for detailed use of the data exchange frame.

### Usage

```squirrel
function makeMifareReadFrame(address) {
    local frame = blob(2);

    frame.writen(0x30, 'b');
    frame.writen(address, 'b');
        
    return PN532.makeDataExchangeFrame(1, frame);
}
```

## PN532.makeCommandFrame(*command [, data]*)

Constructs a command frame for use in [PN532.sendRequest(*requestFrame, responseCallback, shouldRespectPowerSave [, numRetries]*)](#sendrequestrequestframe-responsecallback-shouldrespectpowersave--numretries).

### Parameters

- *command*: The integer corresponding to a PN532 command.
- *data*: An optional blob containing the payload/arguments for the command.

See the [PN532 datasheet](http://www.nxp.com/documents/user_manual/141520.pdf) for detailed use of the command frame.

### Usage

```squirrel
function getFirmwareVersion(callback) {
    local frame = PN532.makeCommandFrame(0x02);

    PN532.sendRequest(frame, callback, true);
}
```

## sendRequest(*requestFrame, responseCallback, shouldRespectPowerSave [, numRetries]*)

Sends the specified *requestFrame* to the PN532 and associates a *responseCallback* to handle the response.  Optionally allows for a maximum number of retries due to transmission failures.

### Parameters

- *requestFrame*: A frame generated by [PN532.makeDataExchangeFrame(*tagNumber, data*)](#pn532makedataexchangeframetagnumber-data) or [PN532.makeCommandFrame(*command [, data]*)](#pn532makecommandframecommand--data).
- *responseCallback*: A function that takes the following arguments:
    - *error*: A string that is null on success.
    - *responseData*: A blob containing the raw response from the PN532 to the request.
- *shouldRespectPowerSave*: A boolean representing whether this request should respect the power save mode state set in [enablePowerSaveMode(*shouldEnable [, callback]*)](#enablepowersavemodeshouldenable--callback). If false, this request will not initiate a power-down after the request. Most calls should try to respect the state, but calls that require state to be stored in the PN532 between commands cannot use it.
- *numRetries*: An optional integer defaulting to 3.

### Usage

```squirrel
function responseCallback(error, responseData) {
    if(error != null) {
        imp.wakeup(0, function() {
            userCallback(error, null);
        });
        return;
    }
            
    // Process responseData...
    server.log(responseData.tostring());
}

local frame = makeMifareReadFrame(0x3);
reader.sendRequest(frame, responseCallback, false);  
```

# PN532 MIFARE Classic Class

## Constructor: PN532MifareClassic(*pn532*)

Associates this class with a previously constructed *pn532* object.

### Usage

```squirrel
#require "PN532.class.nut:1.0.0"
#require "PN532MifareClassic.class.nut:1.0.0"

// ... setup PN532 pins and callback ...

local reader = PN532(spi, nss, rstpd, irq, constructorCallback);
mifareReader <- PN532MifareClassic(reader);
```

## pollNearbyTags(*pollAttempts, pollPeriod, callback*)

A wrapper around the PN532 class's [pollNearbyTags(*tagType, pollAttempts, pollPeriod, callback*)](#pollnearbytagstagtype-pollattempts-pollperiod-callback) method that configures it to search for MIFARE NFC tags.

### Usage

```squirrel
mifareReader.pollNearbyTags(0x0A, 6, scanCallback);
```

## authenticate(*tagSerial, address, aOrB, key, callback*)

Attempts to authenticate the reader to perform operations on a specified EEPROM address.

### Parameters

- *tagSerial*: A blob representing the UID of the tag to be authenticated. This UID can be taken from the response to the [pollNearbyTags(*pollAttempts, pollPeriod, callback*)](#pollnearbytagspollattempts-pollperiod-callback) call.
- *address*: The address of the memory block to be authenticated. For the MIFARE Classic 1k, this is an integer in the range 0-63.
- *aOrB*: The key type to authenticate against.  The options are the static class members `PN532MifareClassic.AUTH_TYPE_A` and `PN532MifareClassic.AUTH_TYPE_B`.
- *key*: The key to use when authenticating for the given block.  If no key has been set, set this parameter to null to use the default FFFFFFFFFFFFh value.
- *callback*: A function taking the following arguments:
    - *error*: A string that is null on success.
    - *status*: A boolean that is set to true if the authentication succeeded.

### Usage

```squirrel
function authCallback(error, status) {
    if(error != null) {
        server.log(error);
        return;
    }
    
    if(authenticated) {
        // Operate on tag...
    }
}

mifareReader.authenticate(tagData.NFCID, 0x2, PN532MifareClassic.AUTH_TYPE_A, null, authCallback);
```

## read(*address, callback*)

Reads 16 bytes from the *address* specified on the currently authenticated tag.

*callback*: A function taking the following arguments:

- *error*: A string that is null on success.
- *data*: A 16-byte blob containing the data read from the tag.

Note that this call will fail with an error if the address being read has not previously been authenticated.

### Usage

```squirrel
// ...authenticate the address...

function readCallback(error, data) {
    if(error != null) {
        server.log(error);
        return;
    }
    server.log(data.tostring());
}

mifareReader.read(0x2, readCallback);
```

## write(*address, data, callback*)

Writes 16 bytes of blob *data* to the *address* specified on the currently authenticated tag.

*callback* is a function taking an *error* string that is null on success.

Note that this call will fail with an error if the address being read has not previously been authenticated or if *data* is not exactly 16 bytes long.  

### Usage

```squirrel
// ...authenticate the address...

function writeCallback(error) {
    if(error != null) {
        server.log(error);
        return;
    }
}

local data = blob(16);
for(local i = 0; i < 16; i++) {
    data[i] = 88;
}

mifareReader.write(0x2, data, writeCallback);
```

# PN532 Card Emulator Class

## Constructor: PN532CardEmulator(*pn532*)

Associates this class with a previously constructed *pn532* object.

### Usage

```squirrel
#require "PN532.class.nut:1.0.0"
#require "PN532CardEmulator.class.nut:1.0.0"

// ... setup PN532 pins and callback ...

local reader = PN532(spi, nss, rstpd, irq, constructorCallback);
cardEmulator <- PN532CardEmulator(reader);
```

## enterTargetMode(*mifareParams, felicaParams, nfcId3, generalBody, onSelect*)

Puts the PN532 in target/card emulation mode.  In this mode, it will appear to be an NFC tag to other readers.

### Parameters

- *mifareParams*: The data necessary to be activated at 106 kbps in passive mode.  This should be constructed with a call to [`PN532CardEmulator.makeMifareParams(sensRes, nfcId1, selRes)`](#pn532cardemulatormakemifareparamssensres-nfcid1-selres).
- *felicaParams*: The data necessary to be activated at 212/424 kbps in passive mode.
This should be constructed with a call to [`PN532CardEmulator.makeFelicaParams(nfcId2, pad, systemCode)`](#pn532cardemulatormakefelicaparams(nfcid2-pad-systemcode)).
- *nfcId3*: A 10-byte blob and is used in the ATR_RES value.
- *generalBody*: The (optional) general data to be used in the ATR_RES value.  If this is set to null, it will be left out.
- *onSelect*: A callback that will be called when the PN532 has been activated by an external reader.  It has the following arguments:
    - *error*: A string that is null on success.
    - *mode*: A table indicating the baud rate and protocol with which the PN532 has been activated.  It has the following fields:
        - *baud*: An integer representing the baud rate.
        - *isPicc*: A boolean indicating whether ISO/IEC 14443-4 PICC mode has been activated.
        - *isDep*: A boolean indicating whether DEP mode has been activated.
        - *isActive*: A boolean indicating whether the PN532 has been activated in active mode. If false, MIFARE/FeliCa framing is in use.
    - *initiatorCommand*: A blob containing the first frame received by the PN532 from the initiator.

### Usage

```squirrel
function onSelect(error, mode, initiatorCommand) {
    if(error != null) {
        server.log("Target mode error: " + error);
        return;
    }
    
    // Mode 0x4 corresponds to MIFARE DEP at 106 kbps
    if(mode == 0x4) {
        // Respond to initiatorCommand
    }
}

// Make a dummy NFC ID
blob nfcId3 = blob(10);
for(local i = 0; i < 10; i++) {
    nfcId3t[i] = i;
}

cardEmulator.enterTargetMode(mifareParams, felicaParams, nfcId3, null, onSelect);
```

## PN532CardEmulator.makeMifareParams(sensRes, nfcId1, selRes)

Constructs the *mifareParams* argument for calls to [`enterTargetMode(mifareParams, felicaParams, nfcId3, generalBody, onSelect)`](#entertargetmodemifareparams-felicaparams-nfcid3-generalbody-onselect).

### Parameters

- *sensRes*: An integer representing the 2-byte (LSB-first) SENS_RES/ATQA value.
- *nfcId1*: A 3-byte blob.
- *selRes*: An integer representing the 1-byte SEL_RES/SAK value.

### Usage

```squirrel
local sensRes = 8; // two bytes are [0x00, 0x08]

// Make a dummy NFC ID
local nfcId1 = blob(3);
nfcId1[0] = 1;
nfcId1[1] = 2;
nfcId1[2] = 3;

local selRes = 0x40;

local mifareParams = PN532CardEmulator.makeMifareParams(sensRes, nfcId1, selRes);

cardEmulator.enterTargetMode(mifareParams, felicaParams, nfcId3, null, onSelect);
```

## PN532CardEmulator.makeFelicaParams(nfcId2, pad, systemCode)

Constructs the *felicaParams* argument for calls to [`enterTargetMode(mifareParams, felicaParams, nfcId3, generalBody, onSelect)`](#entertargetmodemifareparams-felicaparams-nfcid3-generalbody-onselect).

### Parameters

- *nfcId2*: An 8-byte blob.
- *PAD*: An 8-btye blob.
- *systemCode*: An integer representing the 2-byte value used in the POL_RES frame.

### Usage

```squirrel
// Make a dummy NFC ID
local nfcId2 = blob(8);
for(local i = 0; i < 8; i++) {
    nfcId2[i] = 2;
}

local pad = blob(8);
for(local i = 0; i < 8; i++) {
    pad[i] = 3;
}

local systemCode = 0xFFFF;

local felicaParams = PN532CardEmulator.makeFelicaParams(nfcId2, pad, systemCode);

cardEmulator.enterTargetMode(mifareParams, felicaParams, nfcId3, null, onSelect);
```

# License

The PN532 libraries are licensed under the [MIT License](./LICENSE).

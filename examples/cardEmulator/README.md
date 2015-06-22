# PN532 Card Emulator Class

This class allows the PN532 to operate in generic card emulation mode, allowing it to be activated by another reader as if it were an NFC tag.

It uses the extensibility features of the `PN532` base class to add support for extra functionality.

## Constructor: PN532CardEmulator(*pn532*)

Associates this class with a previously constructed *pn532* object.

The *pn532* object must have been constructed with a version of the `PN532` library with a version number in the 1.x.x major revision of at least 1.0.0.

### Usage

```squirrel
#require "PN532.class.nut:1.0.0"

// Include card emulator class

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

The PN532 Card Emulator class is licensed under the [MIT License](../../LICENSE).

# MIFARE Reader Demo

This demo uses the `PN532` and `PN532MifareClassic` classes to create a basic MIFARE Classic ID reader.

## Structure

The code begins by gathering all of the necessary pins and configuring the SPI bus we will need to communicate with the PN532.

It then initializes the PN532 and enable the power-save mode.  Note that this use of power-save will not have a tremendous effect, as it is incompatible with most MIFARE transactions and will be automatically disabled in these cases.

Next, it starts an indefinite auto-poll for tags.  When a tag is found, it is verified to be a MIFARE Classic 1k and if so, we attempt to read an ID field from it.

Finally, the code waits a second to avoid duplicate reads and repeats the polling process.

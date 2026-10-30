# PKG Sender

### Send PS4 PKG files directly from your iPhone — over Network or USB.

PKG Sender is a native iOS app for managing and sending PS4 PKG files. It supports traditional local-network transfers through Remote Package Installer and USB transfers using the built-in Payload v1.0.

**iOS 16+ · Arabic & English · Network + USB transfer**

[Download Latest IPA](https://github.com/T2oDna11/PKGSender/releases/latest) · [View Releases](https://github.com/T2oDna11/PKGSender/releases)

---

## Screenshots

| Home — Network | Home — USB |
| --- | --- |
| <img src="assets/screenshots/home-network.jpg" width="320"> | <img src="assets/screenshots/home-usb.jpg" width="320"> |

| Library | Game Hub |
| --- | --- |
| <img src="assets/screenshots/library.jpg" width="320"> | <img src="assets/screenshots/game-hub.jpg" width="320"> |

| Transfer History |
| --- |
| <img src="assets/screenshots/history-usb.jpg" width="320"> |

## Features

- **USB PKG transfer** with built-in **Payload v1.0**
- **Network PKG transfer** through PS4 Remote Package Installer
- GAME, UPDATE, and DLC package support
- Built-in PKG Library with metadata and artwork
- Game Hub with per-game **Network / USB** transfer selection
- Transfer queue with live progress, speed, and ETA
- Transfer History with:
  - Completed and cancelled transfers
  - Transfer type — **USB / Network**
  - Average speed
  - Peak speed
  - Transfer time
  - Package metadata
- FTP tools
- Local file availability tracking
- Arabic and English interface
- Local transfers — PKG files are not uploaded to a cloud service
- Designed and tested with large PKG files

## USB Transfer

USB mode uses the app's built-in **Payload v1.0**.

1. Connect the iPhone/iPad to the PS4 by USB.
2. Open PKG Sender and select **USB**.
3. Follow the required PS4 payload-loading setup for your environment.
4. Choose a `.pkg` file.
5. Tap **Send to PlayStation**.
6. Keep PKG Sender open until the transfer finishes.

You can also select **USB** directly from a game's Game Hub before sending.

### USB Performance

Real-device testing has included large transfers. One completed **57.6 GB** transfer recorded:

- **21.8 MB/s average**
- **26.2 MB/s peak**
- **45m 45s total transfer time**

A smaller test reached **28.3 MB/s peak**.

Actual performance can vary depending on the iPhone/iPad, PS4, USB connection, package, and system conditions.

## Network Transfer

Network mode uses PS4 **Remote Package Installer (RPI)**.

1. Launch Remote Package Installer on the PS4.
2. Make sure the PS4 and iPhone/iPad are on the same local network.
3. Open PKG Sender and select **Wi-Fi / Network**.
4. Enter the PS4 IP address and check the connection.
5. Choose a `.pkg` file.
6. Tap **Send to PlayStation** and follow the transfer progress.

Default RPI port: `12800`.

## Library & Game Hub

PKG Sender maintains a local library of detected packages and their metadata.

The Library can organize package information and artwork, while the Game Hub groups packages belonging to a title and provides a dedicated **Network / USB** transfer selector.

Supported package types include GAME, UPDATE, and DLC where detected by the available PKG metadata.

## History

Transfer History keeps useful information about previous transfers, including package details, transferred size, average and peak speed, transfer time, date, status, and the transfer method used (**USB or Network**).

## Requirements

### General

- iPhone or iPad running **iOS 16 or later**
- Compatible PS4 environment
- A compatible method for installing the IPA

### Network mode

- PS4 running Remote Package Installer
- iPhone/iPad and PS4 on the same local network

### USB mode

- A compatible PS4 setup capable of loading the included payload
- USB connection between the iPhone/iPad and PS4

## Installation

1. Open the [latest release](https://github.com/T2oDna11/PKGSender/releases/latest).
2. Download the PKG Sender `.ipa` from **Assets**.
3. Install it using TrollStore or another compatible sideloading/signing method.
4. Open PKG Sender.

> The release IPA may require a compatible signing or installation method depending on your device and setup.

## Privacy

PKG Sender works locally. Package metadata, library information, and transfer history are stored on the device. PKG transfers are performed directly between your device and console using the selected transfer method.

## Build from Source

The project is written in Swift/SwiftUI, targets iOS 16+, and can be generated with XcodeGen.

Use the build configuration included in the repository to produce the app for your environment.

## AI Development Notice

PKG Sender was developed with the assistance of artificial intelligence. The application's source code was generated and iteratively refined using AI, while project direction, feature decisions, real-device testing, debugging feedback, and final validation were handled by T2oDna.

## Notes

- Default Remote Package Installer port: `12800`
- Payload version displayed by the app: **v1.0**
- Keep PKG Sender active while a transfer is running.
- Transfer speeds vary by device and setup.
- PKG Sender is an independent project and is not affiliated with Sony Interactive Entertainment.

## Credits

Created by **T2oDna**.

---

**PKG Sender**

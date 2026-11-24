# Badminton Lab

An iOS Swift application for **badminton shuttlecock trajectory analysis**.

This project focuses on video-based shuttle tracking and shot-analysis workflows for badminton match or practice footage.
Introduction video:https://drive.google.com/file/d/1-_XzzuAwotA9j5szZ7IhCDYgHAu9T6I-/view?usp=drivesdk

## Main Workflow

The current recommended workflow is a **single-camera 6-point calibration pipeline**:

1. Import or record a badminton video.
2. Calibrate the court with **BL / BR / TR / TL / Net-L / Net-R**.
3. Run single-camera shot analysis.
4. Review the result on **Camera A**.

## Dual Camera Assisted Analysis

The project also includes a **Dual Camera Assisted Analysis** mode.

In this mode:
- **Camera A** is the main source for segmentation, review, and shot labels.
- **Camera B** is used as an assistant source for false-positive rejection, short-gap recovery, and confidence improvement.
- Stereo 3D points are treated as a support signal instead of the main decision source.

This design improves robustness while avoiding over-reliance on unstable short-baseline phone stereo depth at badminton-court distances.

## Project Structure

- `Badminton Lab/` — Swift source files and app assets
- `Badminton Lab.xcodeproj/` — Xcode project file
- `README.md` — project overview and setup notes
- `.gitignore` — ignores macOS/Xcode-generated files

## Requirements

- macOS
- Xcode
- Swift
- iPhone or simulator for testing

## How to Open the Project

1. Extract the ZIP file.
2. Open `Badminton Lab.xcodeproj` in Xcode.
3. Build and run the app from Xcode.

## Original iOS project author

Kyle Kan

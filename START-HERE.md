# Badminton Lab

Open `Badminton Lab.xcodeproj` in Xcode, select an iPhone simulator running iOS 18 or later, and press Command-R. The app appears as Badminton Lab. Day and Night are available on the home screen, and your choice is remembered.

Use Pick Video to open single-camera analysis and import the matching ball CSV from its toolbar. Use Dual Cam Assist to import both camera views and the matching stereo CSV, calibrate each view, then run assisted analysis. Saved Matches opens the saved match list. Dual Camera Capture requires a supported physical device.

The original TrackNetV3 backend is included in `BadmintonLabBackend`. Its README explains model weight setup and CSV generation. Existing TrackNetV3 CSVs still work with the corresponding source videos and camera order.

From the backend folder, run `python badminton_lab_predict_dual.py --help` for the two-video CSV command. The project uses TrackNetV3 and InpaintNet model weights.

## Import an existing stereo CSV into Simulator

With Badminton Lab running on one simulator, run the following in Terminal to open its Documents folder in Finder. Copy your stereo CSV there, then tap **Dual Cam Assist → Import Dual-View CSV → Browse → On My iPhone → Badminton Lab**.

```sh
open "$(xcrun simctl get_app_container booted org.courtlab.whitehome data)/Documents"
```

## Faster tracking for new videos

Add `--eval_mode nonoverlap` to the dual-camera prediction command. This evaluates consecutive groups of frames once and keeps the same CSV columns. It skips the weighted averaging of overlapping predictions, so compare the detections on your footage. For low-memory Macs, also use `--large_video --batch_size 1 --max_sample_num 16`.

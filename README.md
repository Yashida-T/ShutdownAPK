# Shutdown Scheduler (phone app + PC server)

Control your Windows PC from your phone over Wi-Fi: schedule a shutdown (specific
time or countdown), cancel it, and put the PC to sleep or log out.

```
pc_server/pc_server.py        runs on your PC
app/                          the phone app (Flutter: one codebase -> Android + iOS)
tools/patch_platforms.py      adds network permissions to the generated Android/iOS projects
.github/workflows/build.yml   builds the Android APK and iOS IPA in the cloud
```

## 1. PC side

```
pip install flask
python pc_server.py
```

* Allow Python through Windows Firewall on **private** networks when asked.
* First time a phone connects, click **Yes** on the popup on the PC. After that
  the phone is remembered.
* To start it with Windows: put a shortcut to `pythonw pc_server.py` in `shell:startup`.
* For real sleep (instead of hibernate), run once in an admin Command Prompt:
  `powercfg -h off`

## 2. Get the installers (no developer tools needed on your computer)

1. Create a free GitHub account and a new **private** repository.
2. Upload everything in this folder to it (keep the folder structure, including `.github`).
3. Open the repo's **Actions** tab -> **Build installers** -> **Run workflow**.
4. After ~10 minutes, open the finished run and download:
   * `ShutdownScheduler-android-apk` -> `app-release.apk`
   * `ShutdownScheduler-ios-unsigned-ipa` -> `ShutdownScheduler-unsigned.ipa`

## 3. Install

**Android:** copy the APK to your phone, open it, and allow "install unknown apps" when asked.

**iPhone:** Apple only allows apps signed with an Apple ID.
* Free option: sign and install the `.ipa` with Sideloadly or AltStore using your
  Apple ID. Apps signed this way expire after 7 days and must be re-signed.
* Permanent option: a paid Apple Developer account ($99/year) lets you sign it and
  install through TestFlight.

## 4. Use

Open the app, type your PC's name or IP address (or tap **Scan Network**), and tap
Connect. The top card shows which PC you are connected to.

If the PC name doesn't work, use the IP address (find it with `ipconfig` on the PC).

# 🚗 Installing apps on Geely Cityray (Boyue Cool, G426)

📖 Русская версия: **[README.md](README.md)**

**No root. No custom firmware. No risk to the car.**

On the new Cityray firmware (Android 11, `user` build) normal app installation via ADB is blocked. This toolkit bypasses the block the legitimate way — by calling the system package installer directly. Apps install **permanently** and survive reboots.

**Who it's for:** owners of a Geely Cityray / Boyue Cool (G426) on the new firmware — the one where only the Bluetooth icon is left top-right, and `adb install` fails with `User build type restriction prevents installing`.

### 📦 What's inside

| Component | What it does |
|---|---|
| **`tools/GeelyTool.exe`** | Prepares the flash drive (FAT32 + the `svlog.flag` file) and computes the 6-character ADB activation code. Without it you can't open ADB on the new firmware |
| **`helper/Installer.java`** + `installer.dex` | The core of the bypass: installs APKs through the system `PackageInstaller` API, bypassing the blocked `pm` command |
| **`install.bat`** + `scripts/` | Installs every APK from the `apks/` folder in one click |

Exactly how the bypass works, what was tried, and why everything else fails — in detail in **[DETAILS_TECH_EN.md](DETAILS_TECH_EN.md)**.

> ⚠️ You do this to **your own** car, at your own risk. Nothing here touches the head unit's firmware — we don't write to system storage, we only install apps.

---

## 🧰 What you need

| Item | Notes |
|---|---|
| **Windows** laptop | 10 or 11 |
| **USB flash drive** | 8 GB+ (it will be wiped) |
| **USB-A → USB-C cable** | regular USB (type A) into the laptop, **Type-C into the car**. Connects laptop ↔ head unit |
| App **`.apk`** files | the ones you want to install. Where to get them — see **[ИСТОЧНИКИ.md](ИСТОЧНИКИ.md)** (sources) |

---

## ✅ Step 0. Install ADB (once)

1. Press **Start**, type `PowerShell`, open it.
2. Paste and run:
   ```
   winget install Google.PlatformTools
   ```
3. Close the window. Done.

---

## 🔓 Step 1. Open ADB on the head unit

**1.1. Prepare the flash drive.**
- Plug the flash drive into the laptop.
- Open `tools\GeelyTool.exe` → click **"Yes"** on the admin prompt.
  *(If SmartScreen ("Windows protected your PC") appears → "More info" → "Run anyway".)*
- Click **"1. Prepare flash drive"** → confirm. The flash is now FAT32 with the `svlog.flag` trigger file in the root.

**1.2. In the car.**
- Open the **"Phone"** app, dial `*#32279` — the engineering menu opens.
- Go to **CUSTOMIZATION → ADB → top switch Adb Switch → Open**.
- A **QR code** and a code input field appear.

**1.3. Get the code.**
- Insert the flash into the **car's USB port**.
- Wait for **"Android — OK, QNX — OK"** on screen (the head unit dumps logs to the flash).
- Remove the flash. **❗ Do NOT close the QR code!**
- Plug the flash back into the laptop.
- In `GeelyTool.exe` click **"2. Show code"** — it reads the logs and shows **6 characters** (case-sensitive!).
- Enter those 6 characters into the field under the QR on the car screen → press the **left button** under the QR.
- The QR closes — **ADB is open!** 🎉

---

## 🔌 Step 2. Connect the laptop to the car

Connect the laptop and head unit with a **USB-A → USB-C cable**: regular USB (type A) into the laptop, **Type-C into the car's USB port**.

---

## 📦 Step 3. Add the apps

Copy the `.apk` files you want into the **`apks`** folder (next to `install.bat`).

> Where to get apps (RuStore, Geely-mod packs, etc.) — links in **[ИСТОЧНИКИ.md](ИСТОЧНИКИ.md)**. We don't ship third-party APKs in this repo — only links.

---

## ▶️ Step 4. Install

Double-click **`install.bat`**. Wait for `ИТОГО: OK=... FAIL=0`. Done!

Apps show up in the **GLauncher / GInputBridge** launcher (long-press the media "note" icon in the dock → the "−" icon → the blue icon → all apps are there).

---

## ❗ Important

- ✅ Apps install **permanently**, reboots don't remove them.
- 🔁 **ADB closes after every head-unit reboot.** Re-open it (Step 1) only when you want to install **new** apps.
- ⛔ Replacing **system** apps (same package name, e.g. stock "Settings") is not possible this way.

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| `ADB not found` | Do Step 0, then close and reopen the window |
| `Head unit not connected` | Check the cable (**USB-A → Type-C, data-capable**) and that ADB is open (Step 1) |
| Flash won't format | Run `GeelyTool.exe` as administrator (it asks by itself) |
| Code rejected | Case matters. Did you close the QR? If so, reopen it (Step 1.2) and get a fresh code |
| `FAIL` on install | Likely a system-replacement app — those can't be installed |

---

## 🔍 How it works

Technical details and **full source code** — in [DETAILS_TECH_EN.md](DETAILS_TECH_EN.md). Nothing proprietary, everything open and verifiable.

## 📄 License
MIT — see [LICENSE](LICENSE). Do whatever you want, the author is not liable for anything.

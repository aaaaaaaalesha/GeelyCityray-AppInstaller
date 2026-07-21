# How it works (technical details)

📖 Русская версия: **[DETAILS_TECH.md](DETAILS_TECH.md)**

Firmware (the head unit everything was reverse-engineered and verified on):
- Platform: **DesaySV `geely_g426`** (Boyue Cool / Geely Cityray)
- Android 11, build `RQ3A.210805.001.A1`, build number **1743**
- Build type: **user** (this is the crux — see below)
- Visually: the new firmware where only the Bluetooth icon remains top-right (Wi-Fi / hotspot removed from the status bar)

---

## 0. Where this came from (history)

There are two separate problems here, and they came from different places:

**(A) Opening ADB on the new firmware.** The QR-code + `svlog.flag` method came from the **community** (the "Monjaro" archive, DRIVE2 articles, the 4PDA thread — all in [ИСТОЧНИКИ.md](ИСТОЧНИКИ.md)). Theirs was a closed `start_QR.bat` that did two things: dropped `svlog.flag` on the flash and somehow computed a 6-char code. *How* it computes the code is documented nowhere. We **reverse-engineered the algorithm from scratch** (decompilation + matching against the logs) and rewrote it in the open — that's `tools/GeelyTool.exe` and `scripts/gen_qr.ps1`. So opening ADB is a shared method, but our code tool is entirely our own and open.

**(B) Installing an app once ADB is open.** This is the actual wall, the reason for the whole thing: **ADB is open, shell works, `adb push` works — but installation fails.** In the community the best you'll find is "doesn't install on the new firmware, wait for a fix." We **found the bypass ourselves** by decompiling the system `services.jar`. This is the core of the repo.

Below, in order: what was tried, why it failed, where exactly the lock sits, how we bypassed it, and what an app is actually installed *through*.

---

## 1. What was tried (and why it all failed)

With ADB open, `adb shell` works, shell has its privileges, files copy fine. But **every** normal way to install an APK fails with the same error:

```
java.lang.SecurityException: User build type restriction prevents installing
    at com.android.server.pm.PackageManagerShellCommand.doCreateSession
```

Everything that can install an APK from shell was tried:

| Method | Result |
|---|---|
| `adb install app.apk` | ❌ same error (it's `pm install` under the hood) |
| `pm install app.apk` | ❌ |
| `pm install -r -g --user 0 app.apk` | ❌ (flags don't matter) |
| `pm install-create` → `install-write` → `install-commit` | ❌ fails already at `install-create` |
| `cmd package install ...` | ❌ (same code as `pm`) |
| `pm install -i com.android.vending ...` (spoof the installer) | ❌ |
| set `persist.sv.enable_adb_install=1` and retry | ❌ (see §2 — execution never reaches that check) |

Conclusion: it's not the flags or shell privileges. Something in the system kills session creation outright. Time to read the code.

---

## 2. Why it fails (decompiled services.jar, jadx)

Pulled `/system/framework/services.jar` off the head unit and decompiled it (jadx). The error is thrown in `doCreateSession` of `PackageManagerShellCommand` — which is the **wrapper for the `pm` / `cmd package` command**, i.e. the code that runs when you install from shell:

```java
// com.android.server.pm.PackageManagerShellCommand
private int doCreateSession(InstallParams params, ...) {
    if (Build.IS_USER) {
        throw new SecurityException(
            "User build type restriction prevents installing");
    }
    if (!"1".equals(SystemProperties.get(
                "persist.sv.enable_adb_install", "0"))) {
        throw new SecurityException(
            "Install property restriction prevents installing");
    }
    // ... only after this is the install session created
}
```

Two nested "locks" the vendor (DesaySV) added on top of stock AOSP:
1. `Build.IS_USER` — on a user build this is always `true`, so **the very first `if` kills the install**. `Build.IS_USER` is derived from `ro.build.type=user`; you can't change it at runtime (read-only prop, set at firmware build time).
2. Even if the first lock were removed — the second needs `persist.sv.enable_adb_install=1`. We did set that prop (`setprop`), no effect: execution never reaches the second `if`, it stops at the first. So the prop is a red herring.

**Key takeaway:** the check is not in the installer itself, it's in the **`pm` CLI wrapper**. So the installer underneath may be clean. Let's check.

---

## 3. Key finding

Every app install in Android actually goes through the system service **`PackageInstallerService`** (`com.android.server.pm.PackageInstallerService`) and the public API **`android.content.pm.PackageInstaller`**. The `pm` command is just a thin CLI wrapper that calls that very same API under the hood.

Decompiled `PackageInstallerService` and its `createSession` — and there are **no** vendor `Build.IS_USER` / `enable_adb_install` checks. Only the standard AOSP checks (caller privileges, etc.).

So the lock was placed **only on the `pm` CLI wrapper**, and the installer itself was left open. The obvious move: **call the `PackageInstaller` API directly, bypassing the `pm` command** — installation goes through, because on that path the `Build.IS_USER` check simply doesn't exist.

---

## 4. What an app is installed through (the bypass)

We need to run code that calls the `PackageInstaller` API, and do it as user `shell` (uid 2000) — which on this head unit holds the `INSTALL_PACKAGES` permission. Running your own Java code from shell **without installing an app** (chicken-and-egg!) is possible via the system tool **`app_process`** — the very loader Android uses to start Zygote, the `pm`/`am` commands, Shizuku, scrcpy. Give it a `.dex` in `CLASSPATH` and a class name — it runs your `main()` inside the shell process.

Our helper is [helper/Installer.java](helper/Installer.java) (the built `installer.dex` sits next to it). What it does, step by step:

```
1. ActivityThread.systemMain() → getSystemContext()
   obtain a system Context inside the shell process.
2. context.createPackageContext("com.android.shell", 0)
   switch into the shell package's context — install on its behalf.
3. PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
   SessionParams p = new SessionParams(MODE_FULL_INSTALL);
   int id = pi.createSession(p);          // ← pm died here; here it passes
4. Session s = pi.openSession(id);
   OutputStream out = s.openWrite("apk", 0, apkLength);
   // stream the APK bytes from file into the session → s.fsync(out) → close
5. s.commit(IntentSender);                // commit — the system installs the package
```

We do exactly what `pm install` does internally, but **directly through the API**, where the vendor lock isn't present. It installs **silently**: no dialog, no on-screen confirmation, no root, no reflash. This is a standard, long-known technique (Shizuku, scrcpy, various "adb-tools" apps work the same way) — we just applied it to this particular lock.

Manual run (single app):

```
adb push helper/installer.dex /data/local/tmp/installer.dex
adb push myapp.apk            /data/local/tmp/myapp.apk
adb shell CLASSPATH=/data/local/tmp/installer.dex \
    app_process /system/bin Installer /data/local/tmp/myapp.apk
```

Batch (all APKs in a folder) — done for you by [scripts/install-all.ps1](scripts/install-all.ps1) and `install.bat`: they push `installer.dex`, run each `.apk` from the `apks/` folder in turn, and finish with `ИТОГО: OK=… FAIL=…`.

### Building the dex from source

```
javac --release 8 -cp android.jar Installer.java
d8 --min-api 30 --lib android.jar Installer.class --output .
# produces classes.dex — rename it to installer.dex
```
Needs JDK + Android build-tools (`d8`) + `android.jar` (API 30). A prebuilt `installer.dex` is already in `helper/` — building is optional, it's there for anyone who wants to confirm the dex matches the source.

> Build note: `d8` from a recent JDK (21) chokes on anonymous inner classes. So in the source the callbacks (`IntentSender`, etc.) avoid anonymous classes — interfaces are implemented directly. Small thing, but the dex won't build otherwise.

---

## 5. Opening ADB and computing the code (part "A")

### 5.1. What physically happens
1. Engineering menu `*#32279` → CUSTOMIZATION → ADB → **Adb Switch = Open** → a **QR code** and an input field appear.
2. Insert a FAT32 flash with an empty **`svlog.flag`** file in the root. That file is the trigger: seeing it, the head unit dumps a system `bugreport` onto the flash. **"Android — OK, QNX — OK"** flashes on screen (the car runs two OSes: Android for infotainment, QNX for the cluster / low level).
3. Remove the flash (**don't close the QR!**), plug it into the PC. A `logs_*` folder with `bugreport-*.zip` appears.

### 5.2. What's inside the QR, and why it isn't enough
The QR is base64, protobuf inside. Decoded, it holds: the head unit serial (`sn`), a `salt` (~16 bytes), and another block (~113 bytes). **The password the code is derived from sits in the QR in an encrypted form** — you can't just scan the QR with a phone and get the code. That's why the bugreport path is needed: there the head unit writes the required fields out in plaintext (into a debug log).

### 5.3. How the 6-char code is computed
In one of the `.txt` files inside the zip (search for `QRCodeDialog`) are three fields: **`salt`**, **`password`**, **`sn`** — as byte lists (some values negative — that's Java's `byte` type, convert to unsigned with `b & 0xFF`). The code is effectively **HKDF (RFC 5869)** over HMAC-SHA256:

```
prk  = HMAC-SHA256(key = salt, msg = password)          // HKDF-Extract
h    = HMAC-SHA256(key = prk,  msg = sn_utf8 + 0x01)     // HKDF-Expand, 1 block
code = for the first 6 bytes of h:  charset[ byte % 62 ]
       charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
```

Verify in Python (same thing baked into `GeelyTool` and `gen_qr.ps1`):

```python
import hmac, hashlib
salt     = bytes(b & 0xFF for b in salt_list)
password = bytes(b & 0xFF for b in password_list)
prk = hmac.new(salt, password, hashlib.sha256).digest()
h   = hmac.new(prk, sn.encode() + b'\x01', hashlib.sha256).digest()
cs  = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
print(''.join(cs[b % 62] for b in h[:6]))   # ← 6-char code, case-sensitive
```

The algorithm was checked against the RFC 5869 reference test vector — it matches. The QR is **dynamic**: every `adb switch open` produces a new one → so the code is new each time. `GeelyTool.exe` ("2. Show code") reads the fields from the zip and computes everything itself — you only type the final 6 characters on the head unit screen.

---

## 6. Granting permissions — not blocked

Only installation was cut off. Granting permissions works normally:

```
pm grant <package> <android.permission.XXX>
appops set <package> <OP> allow
```

For example, a stock overlay widget can have its `SYSTEM_ALERT_WINDOW` revoked
(`appops set <pkg> SYSTEM_ALERT_WINDOW ignore`), and a third-party app can be granted the runtime permissions it needs after install.

---

## 7. What stays locked (the method's boundaries)

- **Replacing system apps** (same `packageName`, e.g. the stock "Settings") can't be done this way — needs system level / signature.
- **`pm disable-user` / `enable` of components** from shell is locked on this build: `Shell cannot change component state ...`. You can't disable stock components via shell (we worked around it at the app level — e.g. silencing an overlay via `appops` + force-stop).
- **`cmd car_service ...`** (controlling car functions directly from shell) is also blocked on the user build. That said, the **Car API** itself (`android.car`, vendor properties) is present on the head unit, and a regular app **can** be granted the relevant car permissions via `pm grant` — i.e. controlling car functions is done not from shell but from your own app that declares those permissions. That's a separate topic (not about installing APKs).
- **ADB closes after every head-unit reboot** — you only need to reopen it (§5) to install new apps; already-installed ones stay.

---

## 8. About "your own" firmware

Everything above is verified on build **1743** (`geely_g426`, user). On other builds/platforms:
- the lock condition in `doCreateSession` may differ (different prop name, different `if`) — inspect **your** `services.jar`;
- but the general principle is most likely the same: the lock sits on the `pm` CLI wrapper, while `PackageInstallerService` underneath is clean → the `PackageInstaller` API bypass works.

Nothing proprietary is in this repo: `Installer.java`, `GeelyTool.ps1`, `gen_qr.ps1`, the scripts — all open, readable, and buildable yourself.

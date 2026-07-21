# Как это работает (технические детали)

📖 English version: **[DETAILS_TECH_EN.md](DETAILS_TECH_EN.md)**

Прошивка (ГУ, на котором всё разбиралось и проверялось):
- Платформа: **DesaySV `geely_g426`** (Boyue Cool / Geely Cityray)
- Android 11, сборка `RQ3A.210805.001.A1`, билд **1743**
- Тип сборки: **user** (это ключевой момент — см. ниже)
- Внешне: новая прошивка, где справа вверху осталась только иконка Bluetooth (Wi-Fi / раздача убраны из статус-бара)

---

## 0. Откуда всё пошло (история метода)

Тут две отдельные задачи, и пришли они из разных мест:

**(А) Открыть ADB на новой прошивке.** Способ с QR-кодом и файлом `svlog.flag` пришёл из **сообщества** (архив «Monjaro», статьи на DRIVE2, тема 4PDA — всё в [ИСТОЧНИКИ.md](ИСТОЧНИКИ.md)). У них это был закрытый `start_QR.bat`, который делал две вещи: клал на флешку `svlog.flag` и как-то считал 6-значный код. Как именно он считает код — нигде не описано. Мы **разобрали алгоритм с нуля** (декомпиляция + сверка по логам) и переписали в открытый вид — это `tools/GeelyTool.exe` и `scripts/gen_qr.ps1`. То есть само открытие ADB — метод общий, но наш инструмент для кода полностью свой и открытый.

**(Б) Поставить приложение при открытом ADB.** А вот тут и была засада, ради которой всё затевалось: **ADB открыт, shell работает, `adb push` работает — а установка не идёт.** В сообществе на этот счёт максимум «на новой прошивке не ставится, ждите». Мы **нашли обход сами**, декомпилировав системный `services.jar`. Именно это — главная часть репозитория.

Ниже по порядку: что пробовали, почему падало, где именно стоит замок, как обошли и через что в итоге реально ставится приложение.

---

## 1. Что пробовали (и почему всё падало)

При открытом ADB `adb shell` работает, права shell есть, файлы копируются. Но **любой** штатный способ установки APK падает с одной и той же ошибкой:

```
java.lang.SecurityException: User build type restriction prevents installing
    at com.android.server.pm.PackageManagerShellCommand.doCreateSession
```

Перепробовано всё, что вообще умеет ставить APK из shell:

| Способ | Результат |
|---|---|
| `adb install app.apk` | ❌ та же ошибка (внутри это тот же `pm install`) |
| `pm install app.apk` | ❌ |
| `pm install -r -g --user 0 app.apk` | ❌ (флаги не влияют) |
| `pm install-create` → `install-write` → `install-commit` | ❌ падает уже на `install-create` |
| `cmd package install ...` | ❌ (это тот же код, что и `pm`) |
| `pm install -i com.android.vending ...` (подмена установщика) | ❌ |
| выставить `persist.sv.enable_adb_install=1` и повторить | ❌ (см. п.2 — до этой проверки исполнение не доходит) |

Вывод: дело не во флагах и не в правах shell. Что-то в самой системе рубит создание сессии установки на корню. Надо смотреть код.

---

## 2. Почему падает (декомпиляция services.jar, jadx)

Достали с ГУ `/system/framework/services.jar`, декомпилировали (jadx). Ошибка бросается в методе `doCreateSession` класса `PackageManagerShellCommand` — а это **обёртка команды `pm` / `cmd package`**, то есть код, который выполняется, когда установку запускают из shell:

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
    // ... только после этого создаётся сессия установки
}
```

Два вложенных «замка», добавленных вендором (DesaySV) поверх стандартного AOSP:
1. `Build.IS_USER` — на user-сборке это всегда `true`, поэтому **первый же `if` рубит установку**. `Build.IS_USER` вычисляется из `ro.build.type=user`; на лету его не поменять (read-only проп, задаётся при сборке прошивки).
2. Даже если бы первый замок сняли — второй требует `persist.sv.enable_adb_install=1`. Мы этот проп выставляли (`setprop`), толку ноль: исполнение до второго `if` просто не доходит, всё стопорится на первом. То есть проп — красная селёдка.

**Важный вывод:** проверка стоит не в самом установщике, а именно в **CLI-обёртке `pm`**. Значит, установщик под ней, возможно, чистый. Проверяем.

---

## 3. Ключевая находка

Реальная установка любого приложения в Android идёт через системный сервис **`PackageInstallerService`** (`com.android.server.pm.PackageInstallerService`) и публичный API **`android.content.pm.PackageInstaller`**. Команда `pm` — это просто тонкая CLI-обёртка, которая под капотом дёргает тот же самый API.

Декомпилировали `PackageInstallerService` и его `createSession` — и там **нет** вендорских проверок `Build.IS_USER` / `enable_adb_install`. Только штатные AOSP-проверки (права вызывающего и т.п.).

Значит замок повесили **только на CLI-обёртку `pm`**, а сам установщик оставили открытым. Вывод очевиден: **надо вызвать `PackageInstaller` API напрямую, минуя команду `pm`** — тогда установка пойдёт, потому что на этом пути проверки `Build.IS_USER` просто нет.

---

## 4. Через что ставится приложение (обход)

Нам нужно выполнить код, который дёрнет `PackageInstaller` API, причём из-под пользователя `shell` (uid 2000) — у него на этом ГУ есть разрешение `INSTALL_PACKAGES`. Запустить свой Java-код из shell **без установки приложения** (курица–яйцо!) позволяет системная утилита **`app_process`** — тот самый загрузчик, через который Android запускает и Zygote, и команды `pm`/`am`, и Shizuku, и scrcpy. Даёшь ему `.dex` в `CLASSPATH` и имя класса — он выполняет твой `main()` в контексте shell-процесса.

Наш хелпер — [helper/Installer.java](helper/Installer.java) (собранный `installer.dex` лежит рядом). Что он делает по шагам:

```
1. ActivityThread.systemMain() → getSystemContext()
   получаем системный Context внутри процесса shell.
2. context.createPackageContext("com.android.shell", 0)
   переключаемся в контекст пакета shell — от его имени и ставим.
3. PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
   SessionParams p = new SessionParams(MODE_FULL_INSTALL);
   int id = pi.createSession(p);          // ← на pm падало здесь, тут проходит
4. Session s = pi.openSession(id);
   OutputStream out = s.openWrite("apk", 0, apkLength);
   // льём байты APK из файла в сессию → s.fsync(out) → close
5. s.commit(IntentSender);                // подтверждаем — система ставит пакет
```

То есть мы делаем ровно то же, что делает `pm install` внутри, но **напрямую через API**, где вендорского замка нет. Ставится **тихо**: без диалога, без подтверждения на экране, без root и без перепрошивки. Техника стандартная и давно известная (так же работают Shizuku, scrcpy, разные «adb-tools»-приложения) — мы её просто применили к этому конкретному замку.

Запуск вручную (одно приложение):

```
adb push helper/installer.dex /data/local/tmp/installer.dex
adb push myapp.apk            /data/local/tmp/myapp.apk
adb shell CLASSPATH=/data/local/tmp/installer.dex \
    app_process /system/bin Installer /data/local/tmp/myapp.apk
```

Пачкой (все APK из папки) — за вас это делают [scripts/install-all.ps1](scripts/install-all.ps1) и `install.bat`: сами пушат `installer.dex`, по очереди прогоняют каждый `.apk` из папки `apks/` и в конце пишут `ИТОГО: OK=… FAIL=…`.

### Как собрать dex из исходника

```
javac --release 8 -cp android.jar Installer.java
d8 --min-api 30 --lib android.jar Installer.class --output .
# получится classes.dex — переименовать в installer.dex
```
Нужны JDK + Android build-tools (`d8`) + `android.jar` (API 30). Готовый `installer.dex` уже в `helper/` — собирать не обязательно, это для тех, кто хочет убедиться, что в dex именно то, что в исходнике.

> Примечание по сборке: `d8` из свежего JDK (21) спотыкается об анонимные внутренние классы. Поэтому в исходнике колбэки (`IntentSender` и т.п.) сделаны без анонимных классов — интерфейсы реализованы напрямую. Мелочь, но иначе dex не собирается.

---

## 5. Открытие ADB и расчёт кода (часть «А»)

### 5.1. Что происходит физически
1. Инженерное меню `*#32279` → CUSTOMIZATION → ADB → **Adb Switch = Open** → на экране появляются **QR-код** и поле ввода.
2. Вставляем FAT32-флешку с пустым файлом **`svlog.flag`** в корне. Этот файл — триггер: увидев его, ГУ выгружает на флешку системный `bugreport`. На экране проходит **«Android — OK, QNX — OK»** (в машине две ОС: Android для мультимедиа, QNX — приборка/низкий уровень).
3. Вынимаем флешку (**QR не закрывать!**), вставляем в ПК. Появляется папка `logs_*` с `bugreport-*.zip`.

### 5.2. Что внутри QR и почему его мало
Сам QR — это base64, внутри protobuf. Если раскодировать, там: серийник ГУ (`sn`), некий `salt` (~16 байт) и ещё блок (~113 байт). **Пароль, из которого считается код, в самом QR лежит в закрытом виде** — просто отсканировать QR телефоном и получить код нельзя. Поэтому и нужен путь через bugreport, где ГУ выкладывает нужные поля открытым текстом (в отладочный лог).

### 5.3. Как считается 6-значный код
В одном из `.txt` внутри zip (искать по `QRCodeDialog`) лежат три поля: **`salt`**, **`password`**, **`sn`** — в виде списков байт (часть значений отрицательные — это Java-тип `byte`, приводим к беззнаковым `b & 0xFF`). Код — это по сути **HKDF (RFC 5869)** на HMAC-SHA256:

```
prk  = HMAC-SHA256(key = salt, msg = password)          // HKDF-Extract
h    = HMAC-SHA256(key = prk,  msg = sn_utf8 + 0x01)     // HKDF-Expand, 1 блок
code = для первых 6 байт h:  charset[ byte % 62 ]
       charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
```

Проверка на Python (то же, что зашито в `GeelyTool` и `gen_qr.ps1`):

```python
import hmac, hashlib
salt     = bytes(b & 0xFF for b in salt_list)
password = bytes(b & 0xFF for b in password_list)
prk = hmac.new(salt, password, hashlib.sha256).digest()
h   = hmac.new(prk, sn.encode() + b'\x01', hashlib.sha256).digest()
cs  = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
print(''.join(cs[b % 62] for b in h[:6]))   # ← 6-значный код, регистр важен
```

Алгоритм сверен с эталонным тест-вектором RFC 5869 — совпадает. QR **динамический**: при каждом `adb switch open` он новый → и код каждый раз новый. `GeelyTool.exe` («2. Показать код») читает поля из zip и считает всё сам — руками ничего вводить не надо, кроме итоговых 6 символов на экране ГУ.

---

## 6. Права приложениям — не блокируются

Обрезали только установку. Выдача разрешений работает штатно:

```
pm grant <package> <android.permission.XXX>
appops set <package> <OP> allow
```

Так, например, штатному оверлею-виджету можно снять `SYSTEM_ALERT_WINDOW`
(`appops set <pkg> SYSTEM_ALERT_WINDOW ignore`), а стороннему приложению — выдать нужные ему runtime-разрешения после установки.

---

## 7. Что осталось залоченным (границы метода)

- **Замена системных приложений** (тот же `packageName`, напр. штатные «Настройки») — так не поставить, нужен системный уровень / подпись.
- **`pm disable-user` / `enable` компонентов** из shell залочены на этой сборке: `Shell cannot change component state ...`. Отключать штатные компоненты через shell нельзя (обходили это на уровне приложения — например, глушили оверлей через `appops` + принудительную остановку).
- **`cmd car_service ...`** (прямое управление функциями авто из shell) на user-сборке тоже закрыт. При этом сам **Car API** (`android.car`, вендорские свойства) на ГУ есть, и обычному приложению **можно** выдать соответствующие car-разрешения через `pm grant` — то есть управление функциями машины делается не из shell, а из своего приложения, которое эти разрешения объявляет. Это уже отдельная тема (не про установку APK).
- **ADB закрывается после каждой перезагрузки** ГУ — открывать заново (п.5) нужно только чтобы поставить новые приложения; уже установленные никуда не деваются.

---

## 8. Важное про «свою» прошивку

Всё выше проверено на билде **1743** (`geely_g426`, user). На других сборках/платформах:
- условие блока в `doCreateSession` может отличаться (другое имя пропа, другой `if`) — смотрите **свой** `services.jar`;
- но общий принцип, скорее всего, тот же: замок висит на CLI-обёртке `pm`, а `PackageInstallerService` под ней чистый → обход через `PackageInstaller` API работает.

Ничего проприетарного в репозитории нет: `Installer.java`, `GeelyTool.ps1`, `gen_qr.ps1`, скрипты — всё открыто, читается и собирается самостоятельно.

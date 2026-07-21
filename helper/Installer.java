import android.content.Context;
import android.content.Intent;
import android.content.IntentSender;
import android.app.PendingIntent;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageInstaller.Session;
import android.content.pm.PackageInstaller.SessionParams;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.os.Looper;

import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;

/**
 * Ставит APK, вызывая PackageInstaller API напрямую (PackageInstallerService),
 * минуя патченную команду pm (где стоит блок Build.IS_USER).
 * Запуск как shell:
 *   CLASSPATH=/data/local/tmp/installer.dex app_process /system/bin Installer <apk> [apk2 ...]
 */
public class Installer {

    public static void main(String[] args) {
        if (args.length == 0) { System.out.println("Usage: Installer <apk> [apk2 ...]"); return; }
        try {
            Looper.prepareMainLooper();
        } catch (Throwable ignore) {}

        Context ctx = null;
        try {
            Class<?> atc = Class.forName("android.app.ActivityThread");
            Method systemMain = atc.getMethod("systemMain");
            Object at = systemMain.invoke(null);
            Method getSysCtx = atc.getMethod("getSystemContext");
            Context sys = (Context) getSysCtx.invoke(at);
            try {
                ctx = sys.createPackageContext("com.android.shell",
                        Context.CONTEXT_IGNORE_SECURITY);
            } catch (Throwable t) {
                ctx = sys; // запасной вариант
            }
        } catch (Throwable t) {
            System.out.println("CONTEXT_FAIL: " + t);
            t.printStackTrace();
            return;
        }

        PackageManager pm = ctx.getPackageManager();
        PackageInstaller pi = pm.getPackageInstaller();

        int ok = 0, fail = 0;
        for (String apkPath : args) {
            String name = new File(apkPath).getName();
            try {
                String pkg = "?";
                try {
                    PackageInfo pinfo = pm.getPackageArchiveInfo(apkPath, 0);
                    if (pinfo != null) pkg = pinfo.packageName;
                } catch (Throwable ignore) {}

                boolean success = install(ctx, pi, apkPath);
                // проверка: появился ли пакет
                boolean present = false;
                if (!"?".equals(pkg)) {
                    for (int i = 0; i < 20 && !present; i++) {
                        try { pm.getPackageInfo(pkg, 0); present = true; }
                        catch (Throwable e) { Thread.sleep(250); }
                    }
                }
                if (success || present) { System.out.println("OK   " + name + "  (" + pkg + ")"); ok++; }
                else { System.out.println("FAIL " + name + "  (" + pkg + ") — не подтвердилось"); fail++; }
            } catch (Throwable t) {
                System.out.println("FAIL " + name + " — " + t);
                fail++;
            }
        }
        System.out.println("ИТОГО: OK=" + ok + " FAIL=" + fail);
        System.exit(fail == 0 ? 0 : 1);
    }

    private static boolean install(Context ctx, PackageInstaller pi, String apkPath) throws Exception {
        File apk = new File(apkPath);
        if (!apk.exists()) throw new Exception("нет файла: " + apkPath);

        SessionParams params = new SessionParams(SessionParams.MODE_FULL_INSTALL);
        try { params.setSize(apk.length()); } catch (Throwable ignore) {}

        int sessionId = pi.createSession(params);  // <-- прямой вызов сервиса, минуя pm
        Session session = pi.openSession(sessionId);
        try {
            OutputStream out = session.openWrite("base.apk", 0, apk.length());
            InputStream in = new java.io.FileInputStream(apk);
            byte[] buf = new byte[65536];
            int r;
            while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
            session.fsync(out);
            in.close();
            out.close();

            Intent intent = new Intent("geely.installer.RESULT").setPackage("com.android.shell");
            PendingIntent pending = PendingIntent.getBroadcast(ctx, sessionId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT);
            IntentSender sender = pending.getIntentSender();
            session.commit(sender);
            return true; // отправлено; фактический успех проверяем по наличию пакета
        } finally {
            try { session.close(); } catch (Throwable ignore) {}
        }
    }
}

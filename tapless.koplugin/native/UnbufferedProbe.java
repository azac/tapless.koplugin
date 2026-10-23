package tapless.input;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Temporary, app-window-only Android 8.1 NativeActivity experiment. */
public final class UnbufferedProbe {
    private static volatile String state = "new";
    private static volatile boolean enabled;
    private static long generation;
    private static Object ownedRoot;
    private static Field ownedField;
    private static boolean original;

    private static Method method(Class<?> type, String name, Class<?>... args) throws Exception {
        for (Class<?> c=type; c!=null; c=c.getSuperclass()) {
            try {
                Method m=c.getDeclaredMethod(name,args); m.setAccessible(true); return m;
            } catch (NoSuchMethodException e) { /* Try the parent. */ }
        }
        throw new NoSuchMethodException(name);
    }

    private static Object call(Object target, String name) throws Exception {
        return method(target.getClass(),name).invoke(target);
    }

    private static void restore() throws Exception {
        if (ownedRoot!=null) {
            Object root=ownedRoot; Field field=ownedField;
            field.setBoolean(root,original);
            if (!original) method(root.getClass(),"scheduleConsumeBatchedInput").invoke(root);
            ownedRoot=null; ownedField=null;
        }
        enabled=false;
    }

    public static String status() { return state; }
    public static synchronized boolean enabled() {
        try { return enabled && ownedRoot!=null && ownedField.getBoolean(ownedRoot); }
        catch (Throwable e) { return false; }
    }

    public static synchronized void setMode(final Object activity, final boolean request) {
        final long token=++generation;
        state=request ? "queued:on" : "queued:off";
        Runnable command=new Runnable() {
            @Override public void run() {
                synchronized (UnbufferedProbe.class) {
                    if (token!=generation) return;
                    try {
                        if (!request) { restore(); state="off:restored"; return; }
                        Object window=call(activity,"getWindow");
                        final Object decor=call(window,"getDecorView");
                        Object root=call(decor,"getViewRootImpl");
                        if (root==null) throw new IllegalStateException("detached window");
                        if (ownedRoot!=null && ownedRoot!=root) restore();
                        Field field=root.getClass().getDeclaredField("mUnbufferedInputDispatch");
                        if (field.getType()!=boolean.class) throw new IllegalStateException("field type");
                        field.setAccessible(true);
                        Method unschedule=method(root.getClass(),"unscheduleConsumeBatchedInput");
                        method(root.getClass(),"scheduleConsumeBatchedInput");
                        Field receiverField=root.getClass().getDeclaredField("mInputEventReceiver");
                        receiverField.setAccessible(true);
                        Object receiver=receiverField.get(root);
                        if (receiver==null) throw new IllegalStateException("no input receiver");
                        Method consume=method(receiver.getClass(),"consumeBatchedInputEvents",long.class);
                        if (ownedRoot==null) {
                            original=field.getBoolean(root); ownedRoot=root; ownedField=field;
                        }
                        field.setBoolean(root,true);
                        unschedule.invoke(root);
                        consume.invoke(receiver,Long.valueOf(-1));
                        enabled=field.getBoolean(root);
                        state=enabled ? "on:verified" : "error:readback";
                        // Restoration runs on the Android UI thread even if Lua stops responding.
                        Runnable watchdog=new Runnable() {
                            @Override public void run() {
                                synchronized (UnbufferedProbe.class) {
                                    if (token!=generation) return;
                                    try { restore(); state="off:watchdog"; }
                                    catch (Throwable e) { state="error:restore:"+e.getClass().getSimpleName(); }
                                }
                            }
                        };
                        method(decor.getClass(),"postDelayed",Runnable.class,long.class)
                            .invoke(decor,watchdog,Long.valueOf(90000));
                    } catch (Throwable e) {
                        try { restore(); } catch (Throwable ignored) { /* status remains an error */ }
                        state="error:"+e.getClass().getSimpleName();
                    }
                }
            }
        };
        try {
            method(activity.getClass(),"runOnUiThread",Runnable.class).invoke(activity,command);
        } catch (Throwable e) { state="error:dispatch:"+e.getClass().getSimpleName(); }
    }
}

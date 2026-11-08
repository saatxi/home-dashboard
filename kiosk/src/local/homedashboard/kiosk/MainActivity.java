package local.homedashboard.kiosk;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * Kiosk mínim: un WebView a pantalla completa.
 *
 * URL: la que arriba amb {@code --es url <url>} (es desa) o, si no n'hi ha cap, la pàgina empaquetada
 * a assets (rellotge i data, sense xarxa). Per tornar-hi: {@code --es url ""}.
 *
 * Es queda dins de l'origen de la URL configurada: qualsevol altra navegació es bloqueja.
 */
public class MainActivity extends Activity {

  private static final String TAG = "HomeDashboard";
  private static final String PREFS = "kiosk";
  private static final String PREF_URL = "url";
  private static final String EXTRA_URL = "url";
  private static final String DEFAULT_URL = "file:///android_asset/index.html";
  private static final long RETRY_MS = 5000;
  private static final int BOOTANIM_ATTEMPTS = 2;

  private final Handler handler = new Handler(Looper.getMainLooper());
  private static final String WAITING_HTML =
      "<html><body style='margin:0;background:#000;color:#777;font-family:sans-serif;"
      + "display:flex;align-items:center;justify-content:center;height:100vh;font-size:3vw'>"
      + "Esperant el servidor\u2026</body></html>";

  private WebView web;
  private String url;
  // La càrrega principal ha fallat i hi ha un reintent armat. Android crida onPageFinished també
  // per a la pàgina d'error: sense aquest indicador, aquesta crida cancel·laria el reintent.
  private boolean loadFailed;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    hideSystemUi();

    web = new WebView(this);
    web.setBackgroundColor(Color.BLACK);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setAllowFileAccessFromFileURLs(false);
    s.setAllowUniversalAccessFromFileURLs(false);
    s.setMediaPlaybackRequiresUserGesture(false);
    web.setWebViewClient(new KioskClient());
    setContentView(web);

    url = resolveUrl(getIntent());
    web.loadUrl(url);
    closeBootAnimation();
  }

  @Override
  protected void onNewIntent(Intent intent) {
    super.onNewIntent(intent);
    setIntent(intent);
    String next = resolveUrl(intent);
    if (!next.equals(url)) {
      url = next;
      web.loadUrl(url);
    }
  }

  @Override
  protected void onResume() {
    super.onResume();
    hideSystemUi();
    web.onResume();
    web.resumeTimers();
  }

  @Override
  protected void onPause() {
    web.pauseTimers();
    web.onPause();
    super.onPause();
  }

  @Override
  protected void onDestroy() {
    handler.removeCallbacksAndMessages(null);
    web.destroy();
    super.onDestroy();
  }

  @Override
  public void onBackPressed() {
    // Com a HOME no hi ha enlloc on tornar.
  }

  private String resolveUrl(Intent intent) {
    SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
    if (intent != null && intent.hasExtra(EXTRA_URL)) {
      String requested = intent.getStringExtra(EXTRA_URL);
      prefs.edit().putString(PREF_URL, requested == null ? "" : requested.trim()).apply();
    }
    String saved = prefs.getString(PREF_URL, "");
    return saved.isEmpty() ? DEFAULT_URL : saved;
  }

  private void hideSystemUi() {
    getWindow().getDecorView().setSystemUiVisibility(
        View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
  }

  /**
   * Sense Uhale ningú tanca l'animació d'arrencada. El servei de propietats pot no estar llest al
   * primer inici, per això es prova dues vegades. Si no tenim permís només queda al log.
   */
  private void closeBootAnimation() {
    new Thread(new Runnable() {
      @Override
      public void run() {
        for (int attempt = 0; attempt < BOOTANIM_ATTEMPTS; attempt++) {
          try {
            Process p = Runtime.getRuntime().exec(
                new String[] {"/system/bin/setprop", "sys.bootanim.exit", "1"});
            int rc = p.waitFor();
            Log.i(TAG, "setprop sys.bootanim.exit 1 -> " + rc);
            Thread.sleep(2000);
          } catch (Exception e) {
            Log.w(TAG, "setprop sys.bootanim.exit ha fallat: " + e);
            return;
          }
        }
      }
    }, "bootanim-exit").start();
  }

  /** La pàgina d'espera que dibuixem nosaltres (sense URL pròpia). */
  private static boolean isOwnPage(String pageUrl) {
    return pageUrl == null || pageUrl.startsWith("data:") || "about:blank".equals(pageUrl);
  }

  private boolean sameOrigin(Uri target) {
    Uri base = Uri.parse(url);
    String scheme = target.getScheme();
    if ("file".equals(base.getScheme())) {
      return "file".equals(scheme) && target.toString().startsWith("file:///android_asset/");
    }
    return base.getScheme() != null
        && base.getScheme().equals(scheme)
        && base.getAuthority() != null
        && base.getAuthority().equals(target.getAuthority());
  }

  private class KioskClient extends WebViewClient {
    @Override
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
      boolean allowed = sameOrigin(request.getUrl());
      if (!allowed) Log.w(TAG, "Navegació bloquejada: " + request.getUrl());
      return !allowed;
    }

    @Override
    public void onPageStarted(WebView view, String startedUrl, Bitmap favicon) {
      Log.i(TAG, "pageStarted " + startedUrl + " own=" + isOwnPage(startedUrl));
      if (!isOwnPage(startedUrl)) loadFailed = false;
    }

    @Override
    public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
      if (!request.isForMainFrame()) return;
      // El servidor pot no estar llest a l'arrencada: es torna a provar fins que respongui.
      Log.w(TAG, "Error carregant " + request.getUrl() + ": " + error.getDescription());
      loadFailed = true;
      view.loadDataWithBaseURL(null, WAITING_HTML, "text/html", "utf-8", null);
      handler.removeCallbacks(reload);
      handler.postDelayed(reload, RETRY_MS);
    }

    @Override
    public void onPageFinished(WebView view, String finishedUrl) {
      Log.i(TAG, "pageFinished " + finishedUrl + " failed=" + loadFailed);
      if (loadFailed || isOwnPage(finishedUrl)) return;
      handler.removeCallbacks(reload);
    }
  }

  private final Runnable reload = new Runnable() {
    @Override
    public void run() {
      Log.i(TAG, "reload " + url);
      web.loadUrl(url);
    }
  };
}

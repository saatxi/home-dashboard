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
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.WebResourceError;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

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
  // El rellotge del marc no és fiable: el reinici diari és un retard relatiu des de l'arrencada, no una hora.
  private static final long DAILY_RELOAD_MS = 24L * 60 * 60 * 1000;
  private static final int BOOTANIM_ATTEMPTS = 2;
  // Proteccio contra un renderitzador que mora en bucle (p. ex. WebView massa pesat per a la RAM).
  // Si el renderer mor MAX_RENDERER_DEATHS vegades en RENDERER_WINDOW_MS, el kiosk espera
  // un retard exponencial (1, 2, 4... fins a RENDERER_BACKOFF_MAX_MS) i mostra la pagina empaquetada.
  private static final int MAX_RENDERER_DEATHS = 3;
  private static final long RENDERER_WINDOW_MS = 10L * 60 * 1000;   // 10 min
  private static final long RENDERER_BACKOFF_BASE_MS = 60L * 1000;  // 1 min base
  private static final long RENDERER_BACKOFF_MAX_MS = 30L * 60 * 1000; // 30 min maxim

  private final Handler handler = new Handler(Looper.getMainLooper());
  private static final String WAITING_HTML =
      "<html><body style='margin:0;background:#000;color:#777;font-family:sans-serif;"
      + "display:flex;align-items:center;justify-content:center;height:100vh;font-size:3vw'>"
      + "Esperant el servidor\u2026</body></html>";

  private FrameLayout root;
  private WebView web;
  private String url;
  // La càrrega principal ha fallat i hi ha un reintent armat. Android crida onPageFinished també
  // per a la pàgina d'error: sense aquest indicador, aquesta crida cancel·laria el reintent.
  private boolean loadFailed;
  // Comptador de morts del renderitzador per a la proteccio de retard exponencial.
  private int rendererDeathCount = 0;
  private long rendererWindowStart = 0;
  private int rendererBackoffStep = 0;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    hideSystemUi();

    root = new FrameLayout(this);
    root.setBackgroundColor(Color.BLACK);
    setContentView(root);
    createWebView();

    url = resolveUrl(getIntent());
    web.loadUrl(url);
    handler.postDelayed(dailyReload, DAILY_RELOAD_MS);
    closeBootAnimation();
  }

  /** Crea i configura el WebView i el posa al contenidor; també serveix per substituir-ne un de mort. */
  private void createWebView() {
    web = new WebView(this);
    web.setBackgroundColor(Color.BLACK);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    // file:///android_asset/ (la pàgina de reserva) continua funcionant: aquest paràmetre només tanca
    // la resta del sistema de fitxers. loadDataWithBaseURL no passa per aquí.
    s.setAllowFileAccess(false);
    s.setAllowContentAccess(false);
    s.setAllowFileAccessFromFileURLs(false);
    s.setAllowUniversalAccessFromFileURLs(false);
    s.setMediaPlaybackRequiresUserGesture(false);
    web.setWebViewClient(new KioskClient());
    root.addView(web, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
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
    // Cancel·la tot el pendent: el reintent (reload) i el reinici diari (dailyReload).
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
      String clean = requested == null ? null : requested.trim();
      // "" torna a la pàgina empaquetada; la resta només s'accepta si és http(s) amb amfitrió.
      if (clean != null && (clean.isEmpty() || isHttpUrl(clean))) {
        prefs.edit().putString(PREF_URL, clean).apply();
      } else {
        Log.w(TAG, "URL ignorada (cal http/https amb amfitrió): " + requested);
      }
    }
    String saved = prefs.getString(PREF_URL, "");
    return saved.isEmpty() || !isHttpUrl(saved) ? DEFAULT_URL : saved;
  }

  private static boolean isHttpUrl(String candidate) {
    Uri uri = Uri.parse(candidate);
    String scheme = uri.getScheme();
    String host = uri.getHost();
    return scheme != null
        && ("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme))
        && host != null
        && !host.isEmpty();
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
        && base.getScheme().equalsIgnoreCase(scheme)
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
      onMainFrameFailed(view, request.getUrl() + ": " + error.getDescription());
    }

    @Override
    public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse errorResponse) {
      if (!request.isForMainFrame() || errorResponse.getStatusCode() < 500) return;
      onMainFrameFailed(view, request.getUrl() + ": HTTP " + errorResponse.getStatusCode());
    }

    // API 26+. A l'API 23-25 el mètode no es crida mai: només el seu tipus de paràmetre
    // (RenderProcessGoneDetail) no hi existeix, i ART no el resol fins que s'executa el mètode.
    @Override
    public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
      Log.w(TAG, "El procés de renderitzat ha mort (crash=" + detail.didCrash() + "); recreo el WebView");
      if (view == web) recreateWebView();
      return true; // gestionat: sense això, Android mata l'aplicació
    }

    @Override
    public void onPageFinished(WebView view, String finishedUrl) {
      Log.i(TAG, "pageFinished " + finishedUrl + " failed=" + loadFailed);
      if (loadFailed || isOwnPage(finishedUrl)) return;
      handler.removeCallbacks(reload);
    }
  }

  /** El servidor no respon o falla: pàgina d'espera i nou intent d'aquí a RETRY_MS. */
  private void onMainFrameFailed(WebView view, String what) {
    if (view != web) return; // WebView ja substituït
    // El servidor pot no estar llest a l'arrencada: es torna a provar fins que respongui.
    Log.w(TAG, "Error carregant " + what);
    loadFailed = true;
    view.loadDataWithBaseURL(null, WAITING_HTML, "text/html", "utf-8", null);
    handler.removeCallbacks(reload);
    handler.postDelayed(reload, RETRY_MS);
  }

  /**
   * Substitueix el WebView mort pel seu procés de renderitzat per un de nou amb la mateixa configuració.
   * Si el renderer ha mort masses vegades en poc temps, espera un retard exponencial i mostra la
   * pàgina empaquetada (rellotge) per evitar un bucle que deixaria el marc en negre.
   */
  private void recreateWebView() {
    long now = System.currentTimeMillis();
    // Reinicia la finestra si han passat més de RENDERER_WINDOW_MS des de la primera mort.
    if (rendererDeathCount > 0 && (now - rendererWindowStart) > RENDERER_WINDOW_MS) {
      rendererDeathCount = 0;
      rendererBackoffStep = 0;
    }
    if (rendererDeathCount == 0) {
      rendererWindowStart = now;
    }
    rendererDeathCount++;
    Log.w(TAG, "Mort del renderer #" + rendererDeathCount + " en la finestra actual");

    handler.removeCallbacks(reload);
    loadFailed = false;
    root.removeView(web);
    web.destroy();
    createWebView();

    if (rendererDeathCount >= MAX_RENDERER_DEATHS) {
      // Retard exponencial: 1, 2, 4… fins a RENDERER_BACKOFF_MAX_MS.
      long backoffMs = Math.min(
          RENDERER_BACKOFF_BASE_MS * (1L << rendererBackoffStep),
          RENDERER_BACKOFF_MAX_MS);
      rendererBackoffStep++;
      Log.w(TAG, "Renderitzador massa inestable: esperant " + (backoffMs / 60000) + " min abans de tornar-ho a provar");
      web.loadDataWithBaseURL(null, WAITING_HTML, "text/html", "utf-8", null);
      handler.postDelayed(reload, backoffMs);
    } else {
      web.loadUrl(url);
    }
  }

  private final Runnable reload = new Runnable() {
    @Override
    public void run() {
      Log.i(TAG, "reload " + url);
      web.loadUrl(url);
    }
  };

  // Recàrrega diària de seguretat; si falla, ja s'encarrega el reintent d'onMainFrameFailed.
  private final Runnable dailyReload = new Runnable() {
    @Override
    public void run() {
      Log.i(TAG, "recàrrega diària");
      reload.run();
      handler.postDelayed(this, DAILY_RELOAD_MS);
    }
  };
}

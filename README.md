<p align="center"><img src="docs/icon.png" width="128" alt="Claude RC ikonu"></p>

# Claude RC

macOS menü çubuğu uygulaması. `claude remote-control` sürecini saatin yanından
başlatır/durdurur, durumunu gösterir ve Mac her açıldığında kendini geri
başlatabilir.

> **Orijinal proje [ocracy](https://github.com/ocracy)'ye aittir.** Süreç
> yönetimi, öksüz süreç koruması, log kırpma, girişte otomatik başlatma ve
> oturum adı mantığı onun çalışmasıdır. Bu repoda
> [erenbekman](https://github.com/erenbekman) tarafından eklenenler: SwiftUI
> panel arayüzü ve UI tasarımı, özel ikon, QR kod, bildirimler, universal
> build ve tek komutluk kurulum. Ayrıntılar: [Emeği geçenler](#emeği-geçenler).

![Claude RC paneli — açık ve koyu tema, dört durum](docs/panel.png)

## Kurulum

Gereken: macOS 13+ (Apple Silicon veya Intel) ve kurulu, giriş yapılmış
[`claude` CLI](https://docs.anthropic.com/en/docs/claude-code).

### Tek komut

```bash
curl -fsSL https://raw.githubusercontent.com/erenbekman/claude-rc-menubar/main/install.sh | bash
```

Son sürümü indirir, `/Applications`'a kurar (açıksa eskisini kapatıp
değiştirir) ve başlatır. Güncellemek için aynı komutu tekrar çalıştırın.
Başka bir klasöre kurmak için:
`curl -fsSL … | INSTALL_DIR=~/Applications bash`.

### Elle indirme

[Releases](https://github.com/erenbekman/claude-rc-menubar/releases/latest)
sayfasından `Claude-RC.zip`'i indirip açın, `Claude RC.app`'i Uygulamalar
klasörüne sürükleyin.

Uygulama Apple'a notarize ettirilmediği için tarayıcıyla indirilen kopyayı
macOS ilk açılışta engeller. **Sistem Ayarları › Gizlilik ve Güvenlik ›
Yine de Aç** deyin ya da karantina işaretini kaldırın:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude RC.app"
```

### Kaynaktan derleme

```bash
./build.sh --install     # derler, /Applications'a kopyalar, başlatır
./build.sh               # sadece build/Claude RC.app ve build/Claude-RC.zip üretir
```

Ek olarak Xcode Command Line Tools (`swiftc`) gerekir. Çıktı universal'dır
(arm64 + x86_64).

### İlk açılış

- Menü çubuğunda anten simgesi çıkar; tıklayıp **Çalışma dizini** seçin.
- O dizinde daha önce `claude` çalıştırmadıysanız bir kez terminalden
  çalıştırıp workspace güven onayını verin.
- Bildirim izni sorulur; kopma ve hata uyarıları için izin verin.

## Menü çubuğu

| Simge | Anlamı |
|---|---|
| Anten (soluk) | Kapalı |
| Anten + `…` | Bağlanıyor |
| Anten (net) + sayı | Bağlı — sayı, aktif oturum adedi |
| Ünlem üçgeni | Hata (panelde nedeni yazar) |

Simgeye tıklayınca panel açılır; dışına tıklamak veya `Esc` kapatır.

## Panel

- **Durum rozeti** — Kapalı / Bağlanıyor (nabız atan nokta) / Bağlı / Hata.
- **Durum kartı** — bağlıyken sunucunun bildirdiği oturum adı (kopyala),
  açık kalma süresi, `N / 32` oturum doluluk çubuğu ve
  `claude.ai/code?environment=…` linki (kopyala / tarayıcıda aç). Kapalı,
  bağlanıyor ve hata durumlarında ne yapılacağını söyleyen kısa açıklama.
- **QR kod** — link satırındaki QR düğmesi, ortam linkini QR olarak gösterir;
  telefon kamerasıyla okutup doğrudan bağlanırsınız. Açık/kapalı tercihi
  hatırlanır.
- **Uyarı şeridi** — yeniden deneme veya aynı dizinde başka sunucu gibi
  uyarılar.
- **Başlat / Durdur** (⌘S), **Yeniden başlat** (⌘R)
- **Çalışma dizini** — son kullanılan 8 klasör + `Klasör Seç…`.
  RC açıkken dizin değişirse süreç otomatik yeniden başlar.
- **Oturum adı** — telefonda/claude.ai'de görünen sabit ad; panelde yerinde
  düzenlenir, Enter ya da **Kaydet** ile kaydedilir ve yazarken kaydedilecek
  slug gösterilir. Varsayılan: makine adının slug'ı. Boş bırakılırsa `--name`
  hiç geçilmez ve claude terminaldeki gibi rastgele ad üretir.
- **Ayarlar** (açılır bölüm, açık/kapalı durumu hatırlanır):
  - **Girişte otomatik başlat** — `~/Library/LaunchAgents/com.safepluspay.claude-rc.plist`
    yazıp `launchctl bootstrap gui/$UID` ile kaydeder. Mac her açılışta
    uygulamayı başlatır (uygulama da ayarlıysa RC'yi başlatır).
  - **Açılınca RC'yi başlat** — açılıştan 3 sn sonra (ağ hazır olsun diye).
  - **Mac boşta uyumasın** — IOKit güç iddiası; sadece RC çalışırken tutulur.
  - **Çökerse yeniden dene** — beklenmedik çıkışta artan gecikmeyle 5 deneme.
  - **Bildirimler** — bağlantı koptuğunda, yeniden bağlandığında, RC
    durduğunda (sesli) ve telefondan yeni oturum bağlandığında macOS
    bildirimi. Panel açıkken bildirim gönderilmez; bildirime tıklamak paneli
    açar. Sistem izni kapalıysa ayar satırı bunu söyler.
- **Log** (⌘L) — `~/Library/Logs/ClaudeRC.log`, **Hakkında**, **Çıkış** (⌘Q)

Panel SwiftUI ile, `NSPopover` içinde çizilir; açık/koyu temaya uyar.

## Tasarım

- **İkon** — ince çizgili, minimal bir işaret: sağı açık bir halka (Claude'un
  "C"si), içinde terminal prompt'u `›` ve açıklıktan dışarı çıkan tek bir
  turuncu sinyal yayı. Uygulama ikonu `Sources/makeicon.swift` ile vektörel
  çizilir (açık zemin, lacivert çizgi, turuncu sinyal). Menü çubuğunda aynı
  işaretin 1.2 pt çizgili tek renkli sürümü durur; kapalıyken sinyal yayı
  görünmez.
- **Renkler** — Color Hunt paleti
  [`#000000 #233D4D #FE7F2D #EAECF0`](https://colorhunt.co/palette/000000233d4dfe7f2deaecf0).
  Vurgu açık temada lacivert `#233D4D`, koyu temada turuncu `#FE7F2D`;
  sinyal öğeleri (doluluk çubuğu, QR düğmesi) her iki temada turuncu. Durum
  renkleri paletten türetilip kontrast için ayarlandı (metin ≥ 4.5:1).
- **Ölçüler** — 4-8-12-16 pt boşluk, 8/12 pt köşe yarıçapı, 320 pt panel.

## Nasıl çalışıyor

Süreç şöyle başlatılır:

```
/bin/zsh -lc "cd <dizin> && exec <claude> remote-control --name <isim>"
```

- `-l` (login shell) `.zprofile`/`.zshrc`'yi okur — launchd'nin çıplak
  ortamında bile PATH (Homebrew, nvm) doğru olur.
- `exec` zsh'i claude ile değiştirir; sarmalayıcı süreç kalmaz, `terminate()`
  doğrudan claude'a gider.
- TTY gerekmez; çıktı bir pipe'tan okunur, ANSI temizlenir ve
  `Connected` / `Capacity: N/32` satırları panele yansıtılır.

## Oturum adı neden slug olmak zorunda

İlk sürüm `--name "Jane’s Mac mini"` geçiyordu (boşluk, büyük harf, kıvrık
kesme işareti U+2019). claude'un kendi ürettiği adlar ise katı slug:
`janes-mac-mini-2-local-virtual-aho` — yalnızca `[a-z0-9-]`. Bu ad telefondaki
listede beklenen biçimle eşleşmiyordu. Artık girilen her ad `slugify()` ile
bu biçime çevriliyor; kesme işareti **silinir**, ayırıcıya çevrilmez
(`Jane’s` → `janes`, `jane-s` değil).

TTY'nin bununla ilgisi yok — ölçüldü: pty'li ve pty'siz çalıştırma birebir
aynı sonucu veriyor. Tek fark `--name`'di.

## Öksüz süreç koruması

Uygulama zorla öldürülürse (pkill, çökme, oturum kapanması) macOS
`applicationWillTerminate`'i çalıştırmaz; başlatılan `claude rc` sahipsiz kalıp
sonsuza kadar yaşar ve telefonda hayalet ortam bırakır. İki önlem:

1. **Sinyal yakalama** — SIGTERM/SIGINT/SIGHUP yok sayılır, `DispatchSourceSignal`
   ile karşılanır, çocuk öldürülüp öyle çıkılır.
2. **PID dosyası** — `~/Library/Application Support/ClaudeRC/child.pid`.
   Açılışta kalıntı PID varsa ve gerçekten bir `claude remote-control` süreciyse
   (PID geri dönüşümüne karşı `ps` ile doğrulanır) kapatılır.

Ayrıca aynı dizinde başka sunucu varken panelden başlatılırsa uyarı çıkar ve
"Diğerlerini kapat, başlat" seçeneği sunulur. Temiz kapanan sunucu ortamını
korur ve yeniden başlarken **aynı environment'ı** kullanır; kirli ölen sunucu
ise her seferinde yeni bir ortam yaratır — session yığılmasının sebebi budur.

## Log neden şişmiyor

`claude rc` bir TUI: ekranı silip aynı 5-6 satırı **saniyede bir** yeniden
çizer. Ham dökülseydi log günde ~29 MB, ayda ~880 MB büyürdü. İki kademe var:

1. **Tekrar eleme** — son 16 satırda görülmüş bir satır diske hiç yazılmaz.
   Durum değişmediği sürece yazma olmaz (ölçüldü: 30 sn'de 0 bayt).
2. **Yazma anında kırpma** — dosya 512 KB'ı geçerse son 64 KB korunup gerisi
   atılır. Kontrol her yazmada yapılır, açılışta değil; uygulama aylarca açık
   kalsa da dosya tavanı geçemez.

Yazılan her satır `yyyy-MM-dd HH:mm:ss` damgası alır.

## Notlar

- Uygulamayı taşırsanız, açılışta giriş öğesi kaydı otomatik düzeltilir.
- Yeni bir dizinde ilk kez çalıştırmadan önce o dizinde bir kez `claude`
  çalıştırıp workspace güven onayını vermek gerekir.
- Uygulamadan **Çıkış** yapılırsa RC süreci de kapatılır.
- Bilgisayar tamamen kapalıyken telefondan iş yaptırmak isterseniz bu yetmez;
  o senaryo için cloud session (`claude --cloud`) gerekir.

## Emeği geçenler

- **[ocracy](https://github.com/ocracy)** — Claude RC'nin orijinal yazarı:
  `claude remote-control` süreç yönetimi, öksüz süreç koruması (sinyal
  yakalama + PID dosyası), aynı dizinde çift sunucu uyarısı, log tekrar
  eleme ve kırpma, LaunchAgent ile girişte başlatma, oturum adı slug'ı ve
  ilk menü çubuğu arayüzü.
- **[erenbekman](https://github.com/erenbekman)** — v1.1 ve sonrası:
  SwiftUI panel arayüzü ve UI tasarımı, Color Hunt paletiyle renk sistemi,
  özel uygulama ve menü çubuğu ikonu, QR kod, macOS bildirimleri, universal
  (arm64 + x86_64) build, `install.sh` ve GitHub Releases dağıtımı.

## Dosyalar

```
Sources/ClaudeRC.swift   uygulama (süreç yönetimi + SwiftUI panel)
Sources/makeicon.swift   uygulama ikonu üreteci
build.sh                 derleme (universal) + zip + yerel kurulum
install.sh               son release'i indirip kuran tek komutluk betik
docs/panel.png           panel ekran görüntüsü
docs/icon.png            uygulama ikonu
```

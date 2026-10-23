# Verifiering — 22 oktober 2026

Detta är en kronologisk historik. Tidiga uppgifter om ej installerad drivrutin och ej testad hårdvara är senare ersatta av daterade tillägg. För fortsatt latensarbete, läs [aktuell plan](Docs/LATENCY-PLAN.md).

## Godkänt lokalt

- C++/Objective-C++-bygge: AudioServerPlugIn, Core Audio-brygga, enhetsinventering och tester.
- SwiftUI-app kompilerad för Apple Silicon.
- `core-tests` och `route-tests`: godkända i Release.
- Samma två testprogram: godkända med AddressSanitizer och UndefinedBehaviorSanitizer.
- Bundle-plistor och shellskript: syntaxkontrollerade.
- Lokal ad hoc-signatur: verifierad för app och drivrutinsbundle.
- Appen har öppnats via macOS. Matris och kanallista har inspekterats; separata in-/utfält har testats med 37/21.
- Den skrivskyddade inventeringen har läst riktiga Core Audio-enheter och kanalnamn. Appen visar bland annat UFX Analog, ADAT och MADI samt ZED:s Input-kanaler.
- Senaste UI-avläsning: UFX III 94 in/94 ut, 96 kHz; ZED-R16 18 in/18 ut, 96 kHz.
- Användarens angivna driftfall: UFX III är master, normalt 96 kHz, ZED synkroniserad via ADAT. Slutbyggets standardfrekvens har anpassats till detta.

## Inte verifierat

- Drivrutinen har **inte installerats eller laddats av coreaudiod**. In-process-test är inte bevis för fungerande HAL-publicering.
- Inget ljud har routats till/från användarens kort, och inga inspelningar har gjorts.
- Privat aggregate med den dolda bryggan, mikrofonbehörighet och Abletons beteende behöver testas i verklig drift.
- Ingen faktisk round-trip-latens, bittransparens eller DAW-inspelningsoffset har mätts.
- Inget långtidstest, vilolägestest eller fysiskt frånkopplingstest är utfört.

Inga ändringar har gjorts av RME-/ZED-inställningar, TotalMix, den befintliga Aggregate Device eller macOS standardljudenheter. Inga tjänster, drivrutiner eller automationsjobb har installerats.

## Tillägg: Följ klockmaster

Frekvenssynkning före start och separat synkknapp implementerade. Masterfrekvensen läses; endast avvikande valda fysiska slavkort skrivs. Hela gruppen förkontrolleras. `rate-tests` testar policyn med simulerade läs-/skrivanrop, inklusive asynkron bekräftelse, timeout och avvisade byten. Inget verkligt frekvensbyte har utförts på användarens kort. Byte under pågående ljud stöds inte sömlöst: motorn tystas och stoppas.

## Tillägg: Vilande routingkopplingar

Kanalantalet begränsar nu enbart vilka sparade kopplingar som lämnas till ljudmotorn. Minskning raderar inga rutter. Den fullständiga routingen sparas i preset-filen. Alla fyra testprogram passerar: `core-tests`, `route-tests`, `rate-tests` och nya `preset-tests`. Swift-testet använder samma modell och serialisering som appen och verifierar minskning → sparning/öppning → återökning samt noll kanaler i en riktning. Callback-testet verifierar tystnad för borttagna aktiva rutter och ljud igen efter återaktivering. Detta är tester i process; motsvarande beteende med installerad HAL-drivrutin och fysiska kort är ännu inte verifierat.

## Tillägg: Automatisk sessionssparning

Alla fem testprogram passerar efter införandet av `session-tests`. Det nya testet instansierar appens riktiga `Model` med isolerad temporär sessionsfil och utan hårdvaruinventering. Det kontrollerar automatisk sparning vid direkta fält-/routingändringar, återställning i en ny modell, vilande kopplingar, 0/0 som redigeringsläge, tom kortlista, ökat kanalantal före UI-normalisering, säkerhetskopia av trasig fil och synligt skrivfel. Ingen avslutningssignal eller manuell sparning behövs. Den uppdaterade appen har också avlästs i macOS och visar ”Ändringar sparas automatiskt”. Full avslutning/omstart via UI med användarens routing har inte verifierats.

## Tillägg: Egna kanaletiketter

Alla fem testprogram passerar. Sessionstestet verifierar separata etiketter för samma kanalnummer på olika kort och i olika riktningar, automatisk återställning, preset-export samt borttagning av en etikett utan att ändra den andra riktningens etikett eller routingen. Presentationen behåller originalnamnen. Äldre presets utan etikettfält fungerar. Appen har startats om och etikettredigeraren har öppnats och inspekterats med tillgänglighetsträd och skärmbild. Testetiketter har inte skrivits till användarens session.

## Tillägg: Låsta matrisrubriker

Matrisen använder nu en gemensam NSScrollView för rutorna och två fasta rubrikytor som följer scrollpositionen längs respektive axel. Alla fem testprogram passerar i slutbygget. Visuellt kontrollerat i appen: sidscrollning till MADI-kanalerna behåller DAW-ingångarnas radnamn till vänster; nedscrollning i uppspelningsmatrisen till UFX ADAT/MADI behåller DAW-utgångarnas kolumnnamn överst. En initial ritningsbugg där bakgrunder målades utanför delvyerna rättades med uttrycklig klippning och begränsad bakgrundsfyllning. Ingen routing eller hårdvaruinställning ändrades vid scrollkontrollen.


## Tillägg: Musmarkering och direkt etikettredigering

Alla fem testprogram passerar i slutbygget. Sessionstestet verifierar kanalval i etiketteditorn, separata virtuella DAW-etiketter samt matrisens rad-/kolumnindex efter scrollning, gränskontroll och att musmarkering inte ändrar routing. Originalnamn och egna etiketter ritas nu separat så att texttrunkering inte döljer etiketten.

Visuellt kontrollerat i appen: den befintliga etiketten RE-201 visas under ZED-R16 Input 1. Dubbelklick på den kanalrubriken öppnar rätt riktning i etiketteditorn med RE-201 markerad i textfältet. Rad, kolumn, båda rubrikerna och rutans ram markeras vid muspositionen i matrisen. Senaste appbygget är öppet. Användarens etiketter, routing och ljudinställningar ändrades inte under dessa UI-kontroller.


## Tillägg: To Computer / From Computer och härledda etiketter

Alla fem testprogram passerar. Appens kanalrubriker, riktningar, antal-fält, kanallista och feltexter använder nu To Computer/From Computer. Etiketteditorn innehåller endast hårdvarans in- och utgångar. Sessionstestet verifierar härledning från routing, flera destinationer, uppdaterad hårdvaruetikett, reservnamn utan etikett, frånkoppling, vilande/återaktiverade kanaler, att äldre virtuella etiketter ignoreras och att dubbelklick väljer den anslutna hårdvarukanalen.

App och driver är byggda och signaturkontrollerade. UI-verktyget kunde läsa det äldre öppna bygget men avvisade omstart/stängning med meddelandet att appen ändrats, även efter återanslutning. Det nya gränssnittet är därför inte visuellt verifierat i denna omgång; det nya bygget ligger i Dist/StudioPatch.app. Ingen drivrutin installerades.


## Tillägg: Bekräftelse vid avmarkering av ljudkort

Alla fem testprogram passerar. Sessionstestet verifierar att avmarkering av ett kort med vilande routing kräver bekräftelse, att avbrott behåller kort och kopplingar, att bekräftelse tar bort kortets kopplingar utan att röra ett annat kort, samt att val och avmarkering av kort utan routing sker direkt. Nytt appbygge finns i Dist; dialogen har inte kontrollerats interaktivt i denna omgång.


## Tillägg: Härledda kanalnamn i Core Audio

Den synliga enheten implementerar `kAudioObjectPropertyElementName` för in- respektive ut-scope, element 1 till aktuellt kanalantal. `kAudioDevicePropertyChannelNameCFString` är samma selector enligt det lokala macOS SDK:t. Namnen skickas från appen via en separat plugin-egenskap och uppdateras utan format-/IO-omkonfiguration; egenskapsnotiser skickas bara för ändrade element. Namnlagring, låsning och notifieringar ligger utanför realtidscallbacken.

Alla fem testprogram passerar. Core-testet använder drivrutinens faktiska property-implementation för scope/element, storlek, ägarskap för CFString, läsbarhet, reservnamn, svenska tecken, citattecken och bakstreck, tomma namn, felaktiga antal och noll utkanaler. En simulerad host verifierar rätt ändringsnotiser, oförändrat enhets-ID vid namnbyte med aktiv I/O samt beständig lagring/återläsning via initialiseringskoden. Swift-testet verifierar att publicerade namn härleds från samma routing som matrisen, inklusive flera destinationer och oanslutna kanaler. App och driver är byggda och signaturkontrollerade.

Ingen drivrutin installerades och Core Audio startades inte om. Tester körs i process; publicering via den riktiga HAL-processen och namnvisning/uppdatering i Ableton återstår. Den redan öppna appen har inte startats om i denna omgång.


## Tillägg: Valda ljudkort som inte är tillgängliga

Senast kända kortnamn, kanalnamn/antal och frekvens sparas som valfri metadata i session/preset. Tillgänglighet avgörs alltid från aktuell inventering per UID; gamla AudioDeviceID sparas inte. Frånkopplade kort behålls i listan och matrisen med grå rubriker, etiketter och kopplingsrutor. Matrisens klickkontroll och modellens gemensamma setters tillåter bara borttagning av kopplingar för otillgängliga kanaler. Kanallistan använder samma setters och blockerar otillgängliga val. Bekräftelse vid avmarkering omfattar även dessa kort och vilande rutter.

Alla fem tester passerar. Utökade sessionstester simulerar inventering → frånkoppling → sparning/omstart → redigering → återanslutning med nytt runtime-ID → avmarkering. De kontrollerar hela kanaluppsättningen inklusive oroutade kanaler, etiketter och härledda namn, preset-export, blockerad ny routing, tillåten borttagning i båda riktningar, varning för vilande routing och matrisens klickspärr. Inga fysiska ljudkort kopplades från och ingen användarrouting ändrades.

Efter användarens godkännande öppnades det isolerade UI-testbygget med påhittade kort och separat sessionsfil. Visuellt verifierat: utgråat kort med ikryssad och klickbar kryssruta, alla fyra in-/utkanaler kvar, sparade etiketter och grå kopplingsrutor i båda matriserna. UI-klick och kontroll av testappens sparade session verifierade att befintliga kopplingar kan tas bort, att nya och återställda kopplingar blockeras i båda riktningarna samt att kanallistan också blockerar val av frånkopplad ingång. Varningen visar kortets namn. Avbryt behåller kortet och routingen; Koppla bort tar bort kortet och dess kopplingar i båda riktningar. Inga riktiga ljudkort eller användarinställningar ändrades.


## Tillägg: Automatisk frekvenssynkning

Den manuella knappen är borttagen och kryssrutan heter Följ klockmaster. Inventering jämför valda kort och appfrekvens mot aktuell master. Synkning körs på en bakgrundsuppgift; en separat försöksserie gör ett första försök, tre direkta återförsök och sedan fem sekunders väntan efter varje misslyckande. Avmarkering och ändrat master-/korturval avbryter den gamla serien. Redan påbörjade synkrona drivrutinsanrop kan behöva avslutas. Routing stoppas före synkning; namn-/kanalpublicering och ljudstart konkurrerar inte med den aktiva automatiska serien. Fel visas som status i sidopanelen.

Alla fem tester passerar. Retry-policyn är testad för tre direkta återförsök, fortsatt femsekundersintervall och ny försöksserie. Befintliga rate-tests täcker drivrutinsfel, timeout och masterbyte via simulerade anrop. Hela asynkrona UI-förloppet och verkliga frekvensbyten på ljudkorten är inte verifierade i denna omgång. Appen har inte startats om.

### Automatisk transportmarginal

Automatik är standard även för äldre sessioner och använder fyra valda I/O-buffertar per riktning. Motorns payload innehåller den beräknade marginalen, medan sessionsfil/preset behåller manuellt värde och automatikval separat. UI visar samples och ms per riktning och placerar manuell inställning under Avancerat. Preset-tester verifierar byte av buffert/frekvens, motorpayload, manuellt läge, återställning och äldre format. Alla fem testsamlingar passerade; app och driver byggdes och signaturverifierades. Ingen ny fysisk ljud- eller latensmätning utförd.

## Rättad uppslagning av installerad drivrutin — 23 oktober 2026

Vid första verkliga HAL-testet gav den synliga enhetens owner systemobjektet (1), inte pluginobjektet. Appen svalde property-läsfelet, och tom sträng gav Invalid channel count, sample rate or transport delay vid publicering av kanalnamn. Bridge använder nu kAudioHardwarePropertyTranslateBundleIDToPlugIn med se.studiopatch.driver och rapporterar property-läsfel direkt. Verifierat mot installerad drivrutin: korrekt plugin-ID 58 och konfiguration 1 18 18 96000 256. Alla fem testsamlingar passerar. Rättad app öppnad utan fel; Tillämpa kanalantal bekräftades i UI. Ingen ominstallation av driver behövdes. Audio-start och Ableton-ljud är ännu inte verifierade.

## Deadlock vid start — 23 oktober 2026

Användarens hängrapport visar Model.start → SPConfigure → SetPropertyData → PatchPlugin.configure → Storage.WriteString, med en explicit deadlock mellan drivrutinens XPC-tråd och Core Audios ändringsköer. Host-lagring har flyttats till en separat seriell dispatch-kö med oföränderliga snapshots och utan att kön tar konfigurationslåset. Samma rättning används för kanalnamn. Appens atomiska sessionsfil finns kvar som primär lagring. Nytt regressionstest låter host-sparningen återanropa konfigurationsgettern och kontrollerar att två snapshots sparas i ordning. Kärntestet har 20 sekunders timeout. Alla fem testsamlingar passerar; app och driver byggda och signaturverifierade. Detta är ännu inte verifierat med den uppdaterade drivrutinen laddad i HAL. Installationsskriptets --replace bevarar den tidigare identifierarvaliderade drivrutinen utanför HAL-katalogen. Användaren behöver uppdatera med administratörsrättigheter och starta om innan nytt ljudtest.

## Återstående deadlock i PropertiesChanged — 23 oktober 2026

Ny faktisk drivrutinssampling /tmp/StudioPatch-driver-hang.txt visar Stream.SetIsActive → Object.NotifyPropertiesChanged → synkront XPC-svar från Core Audio. Appsamplingen visar huvudtråden i Model.init → SPInventory → HAL-enhetsuppräkning. Förra rättningen av lagringsanropet var otillräcklig: host-notifieringar gjordes fortfarande på HAL:s anropstråd.

Lokal libASPL-rättning: PropertiesChanged och RequestDeviceConfigurationChange skickas nu från separat seriell host-kö, med kopierade data och kvarhållen objektlivstid. Lagringens separata kö behålls. Regressionstestet använder riktig Stream.SetPropertyData(IsActive) och en simulerad host som väntar på att settern återvänder; synkron notifiering skulle låsa testet. Befintliga kanalnamnstester inväntar nu notiskön.

Alla Core Audio-anrop från Swift-modellen flyttades till en seriell bakgrundskö, inklusive inventering, namn, konfiguration, start/stopp, status och frekvenssynkning. En pågående operation blockerar nya anrop från polling/knappar; efter fem sekunder visas väntestatus utan att låtsas avbryta anropet. Avslut försöker stoppa motorn men väntar högst två sekunder på ljudservern. Okänd enhetsstatus skiljs från en lyckad inventering utan StudioPatch. Nytt async Model-test blockerar inventering med semaphore och verifierar att MainActor fortsätter, parallell polling inte köar nya läsningar och status blir känd efter frigörning. Alla fem testsamlingar passerar; app/driver byggda och signaturverifierade. Uppdaterad drivrutin måste installeras och laddas efter omstart innan verkligt ljudtest. Ingen automatisk omstart av ljudserver eller dator gjordes.

## För snävt buffertintervall i Ableton — 23 oktober 2026

Read-only HAL-probe mot installerad drivrutin visade StudioPatch ZeroTimeStampPeriod=128 och BufferFrameSizeRange=29..48, medan UFX III och BlackHole rapporterade period=16384 och intervall=29..4096. Det förklarar varför endast 32 är en vanlig tvåpotensstorlek i Abletons val. SDK:s AudioServerPlugIn.h dokumenterar minst 10923 frames för ZeroTimeStampPeriod. Båda StudioPatch-ändpunkter använder nu RingFrames=16384 för både den annonserade perioden och kvantiseringen av GetZeroTimeStamp. Transportfördröjning och I/O-buffertstorlek är oförändrade; klockperioden innebär inte att en hel ring måste fyllas före läsning.

Regressionstest verifierar periodens minimigräns, identiska annonserade perioder, timestamps på periodgränser, gemensam seed och tidsbas. Alla fem testsamlingar passerade. CPU-ögonblicksbild före rättning: Ableton ca 199 %, ZED-drivrutin 41 %, coreaudiod 15 %, RME 12 %, StudioPatch-app 1,3 % (processprocent, inte Abletons egen ljudbelastningsmätare). Ableton-sampling visar aktiv ljudbearbetning inklusive plugins; ingen ensam orsak till all CPU-belastning fastställd. Nytt faktiskt buffertintervall och CPU efter ändringen måste verifieras efter installation och omstart. Ingen drivrutin laddades om i denna felsökning.

## Stabil statuslayout och en stoppknapp — 23 oktober 2026

Användarens skärminspelning visade två överlappande stoppknappar. Sidopanelens inställningar har nu egen disabled-grupp; samma enda start/stoppknapp ligger utanför den gruppen och overlay-knappen är borttagen. Rutinpolling visar inte längre en tillfällig statusrad. Operationsstatus har reserverad höjd även när den är tom; ljudstatus begränsas till en rad med monospaced siffror så att cykelräknaren inte ändrar layoutens höjd. Femsekundersvarningen och serialiseringen av Core Audio-anrop behålls.

Alla fem tester passerade. Async modelltest kontrollerar att rutinpolling är tyst men fortfarande blockerar överlappande native-anrop. App byggd och signaturverifierad. Den pågående användarappen startades inte om; den nya layouten är ännu inte visuellt verifierad i den körande appen. Ingen drivrutinsinstallation behövs för denna UI-ändring.

## Bakgrundstjänst och automatiska formatbyten — 23 oktober 2026

StudioPatchService är en separat signerad körfil i apppaketet. Den fortsätter oberoende av kontrollpanelens fönster/process. Kontrollpanelen sparar önskemål atomiskt; tjänsten är enbart läsare av sessionen och ensam ägare av ljudmotorn. Tidsstämplad status med enhetsinventering läses av panelen. Start/stopp/Tillämpa är borttagna ur UI och routing/kanaler går att redigera under drift. Tjänsten tillämpar ändringar och återförsöker automatiskt. Rena routingändringar gör för närvarande en kort transportomstart, inte ett avbrottsfritt snapshotbyte.

Driver: HAL-schemalagda ändringar på befintliga endpoint-ID:n, nya strömmar och gemensam session. Gamla och nya ringar hålls tysta under övergången; readiness publiceras först när båda endpoint-konfigurationerna bekräftats. Asynkrona completion-callbackar tar inte pluginlåset under enhetens lås. Abort lämnar ljudet tyst. Ny tidsbas ger ny timestamp-seed. AvailableNominalSampleRates och tillåtna strömformat kommer från masterkortet inom 8–384 kHz. Klientens nominella/strömformatsbegäran publiceras till tjänsten; tjänsten ställer först master och sedan övriga kort, verifierar frekvens, byter virtuell konfiguration och startar transport. Acknowledgement använder compare/exchange så att en senare begäran inte raderas av ett gammalt svar.

Systemnotiser begärs av kontrollpanelen och skickas av tjänsten endast om macOS har beviljat tillstånd. Ett fel ger högst en notis fram till återhämtning. Fel visas i panelens status utan felmodal. Inloggningsstart förbereds av install-service.sh utan sudo; helperns single-instance-lås förhindrar dubbla motorer.

Alla sex testsamlingar passerar inklusive utökade core-tests för aktiv konfiguration, stabilt enhets-ID, 4/2 och 1/0, prefererat kanalantal, 192 kHz, formatlista och mutad gammal ring. Scripts/test-runtime.sh bygger riktig Swift-service/Model med en simulerad native-backend och kör den som separat process: automatisk start utan panel, singleton, ändrade routes, tystnad vid fel, automatisk återhämtning och kvitterad klientfrekvens passerar. Testfilerna isoleras från användarsessionen. Detta är inte ett fysiskt ljudtest; faktisk HAL/Ableton-verifiering, inloggningsstart och systemnotiser kräver installation och användartest. Den körande äldre appen och systemets installerade driver har inte ändrats.

## HAL-registrering av frekvensstyrning — 23 oktober 2026

Efter användarens installation/omstart var tjänsten aktiv men rapporterade att en ny driver behövdes. SHA-256 för installerad driver och distribuerad driver var identiska (cb4b0a592577a58b95e045692061e49209e6fc12c0719b644d04ba5d0f06fa1d). Felet var alltså inte en missad installation. RatesProperty (sprt) hade HasProperty/SetPropertyData-implementation men saknades i RegisterCustomProperty och därmed i HAL:s CustomPropertyInfoList. Detta hindrade klienten från att se egenskapen via Core Audio. Den registreras nu som CFString och kan läsas tillbaka. Nytt regressionstest kontrollerar att samtliga sex använda custom properties finns i HAL-registret med korrekt datatyp, samt att frekvenslistan går att läsa. Native-feltexten beskriver nu den saknade egenskapen i stället för att påstå att rätt version inte installerats. Rättningen behöver installeras och laddas om innan verklig ljudstart kan verifieras.

## Frekvenspayload och återställning före HAL-publicering — 23 oktober 2026

Faktiskt installerad och distribuerad driver hade identisk SHA-256 f8db7ebd0caf984d391123973dee4254884ed28a60f6c8eb3b70440443dd35aa. Felet 1852797029 är 'nope'. UFX III rapporterade sju frekvenser: 32000, 44100, 48000, 88200, 96000, 176400, 192000. Den långa numeriska texten överskred serverns konservativa 256-byte UTF-8-allokeringsgräns. RateWire använder nu kortare förlustfri exponentnotation där det sparar plats. Regressionstest skickar just UFX-listan genom driver.SetPropertyData och verifierar samtliga värden och CFString-gränsen. Live-probe mot installerad HAL accepterade listan och returnerade masterRate=96000, requested=0.

Efter uppdatering av bakgrundstjänsten synkroniserades både ZED och UFX till 96000. Nästa fel var Begär virtuell konfiguration 'nope'. Read-only live-probe visade Ready=0 och kvarvarande defaultkonfiguration 1 18 18 96000 256. Initialize återställde sparad konfiguration med asynkrona förändringsbegäranden för enheter HAL ännu inte publicerat. Dessutom ignorerades omedelbart avslag från host.RequestDeviceConfigurationChange, vilket lämnade configuring-flaggan satt.

Restore under Initialize kopplar nu tillfälligt loss de ännu opublicerade endpoint-objekten från pluginhierarkin, utför deras konfiguration synkront och återansluter dem före Initialize returnerar. Runtime-ändringar använder fortfarande HAL:s asynkrona mekanism. LibASPL aborterar uttryckligen en begäran som host omedelbart nekar. Regressionstest verifierar att initial återställning inte skickar konfigurationsbegäranden, att Ready är sant efter återställning samt att avslag under drift släpper pending-läget och tillåter nytt försök. Denna drivrutinsändring kräver installation/omstart; faktisk ljudstart kan därför inte bekräftas i samma körning.

## Format notifications (2026-10-23)

The background service now sends macOS notifications for successful sample-rate or exposed channel-count changes, and for failed attempts. Notifications include the requested rate, To/From Computer channel counts and selected hardware names. Success is sent only after configuration, engine startup and client-request acknowledgement complete. A pending format change survives partial failure so eventual recovery also reports success. Repeated failures for the same target are suppressed until recovery; ordinary routing edits and startup with an already matching format are silent. Notification submission errors are logged. Display remains subject to macOS notification permission and Focus settings.

Validation: all six CTest suites pass. The separate-process runtime integration test exercises actual Swift service decisions against the fake native backend, including silent matching-format startup/routing edits, one failed-format event across immediate retries, a recovery success event, and exactly one success for a client sample-rate request. Notification events are captured to an isolated test file instead of displaying system banners. Real macOS banner delivery and a live Ableton format change have not been exercised by this automated test.

## Live Ableton format test (2026-10-23 morning)

Ableton Live 12 Suite selected StudioPatch as both input (4 channels) and output (2 channels), with a 256-sample Ableton buffer. Changing Ableton from 96 kHz to 48 kHz updated StudioPatch, UFX III and ZED-R16 to 48 kHz with routing active and zero reported bad buffers. Selecting 96 kHz in StudioPatch then updated Ableton and both physical devices to 96 kHz. Playback/test tone stayed off. This confirms control/format propagation, not measured audio latency or dropout-free audio during transition.

The user reported no notifications for either transition. System Settings shows StudioPatch notifications enabled for Desktop and Notification Center. Service logs show notification settings fetched but the original authorization guard prevented submission. Diagnostic removal of that guard results in an explicit delivery error; notification delivery is under investigation.

Notification diagnostics: service authorizationStatus was 0 (notDetermined); submission and requestAuthorization both fail with UNErrorDomain code 1. A stable service code-signing identifier alone did not fix this. Notifications remain unverified/nonfunctional from the LaunchAgent. The local builds are ad-hoc signed; no valid certificate-backed code-signing identities were found by security find-identity. Repeated microphone permission prompts may be related to this signing setup, but that causal connection has not been verified from TCC logs.

A later frequency restore exposed competing panel/client rate requests: a retained panel request could override a pending driver request, preventing configuration readiness. Client rate requests now take priority and discard the stale panel request.

## Certificate signing and notification correction

The notification failure was resolved by signing the embedded service with identifier se.studiopatch.app, matching its enclosing app. macOS accepted format-changed notifications and the user confirmed a visible notification. Merely choosing a separate stable service identifier did not work.

The previous 'no valid identities' result was obtained inside the sandbox and was misleading. A permitted unsandboxed Keychain query found Apple Development and Developer ID identities. The app and service are now signed with the same Apple Development certificate (local development team), and their designated requirements are identical and certificate-based rather than code-hash-based. Scripts/signing-identity.txt holds only the public certificate fingerprint; private keys remain in Keychain. build.sh uses this identity by default and fails rather than silently falling back to ad-hoc signing. STUDIOPATCH_SIGNING_IDENTITY can explicitly override it on another developer's Mac. Certificate replacement requires updating that configuration.

Initial transition from ad-hoc signing may require permission again. Persistence across subsequent builds is to be checked. Six CTest suites and the runtime integration tests pass. The driver installed in Core Audio is unchanged; the packaged driver is signed but no driver installation was performed.

Certificate transition verification: TCC explicitly reported failure to match the former ad-hoc cdhash against the new Apple Development designated requirement. The visible app now explicitly requests audio capture permission when notDetermined. At 08:44:45, TCC logged AUTHREQ_PROMPTING for se.studiopatch.app / Microphone. Final user consent and subsequent engine-start/rebuild persistence verification remain pending; the engine was waiting in AudioDeviceStart. Do not claim microphone persistence fully tested until this consent and a subsequent restart complete.

Final permission verification, 08:47–08:49: user granted the certificate-based microphone prompt. TCC recorded Allowed (User Consent) for both the panel and old running signed service. Restarting into the newer signed service (PID 6608) reused Allowed (User Consent), without a new AUTHREQ_PROMPTING event, and routing resumed at 96 kHz with zero reported bad buffers. A live Ableton 96→48 kHz change produced Notification accepted: format-changed from that signed service at 08:48:32. Ableton was restored to 96 kHz. The user had already confirmed seeing a notification after the identifier correction. Certificate-based permission persistence across these two signed builds is verified; no machine reboot was required or tested.

### Hot-unplug inventory isolation (2026-10-23)
- Hardware discovery no longer fails when StudioPatch plug-in configuration cannot be read.
- Ignore non-alive devices and isolate per-device C++ property-read failures during hot unplug.
- Missing selected hardware is reported before virtual-driver availability errors.
- Live verification with disconnected ZED-R16: checked device retained, greyed out, last-known 18 inputs/18 outputs shown, missing-device status identifies ZED-R16.
- Runtime regression exercises inventory updates during retry backoff, retained selection, and automatic reconnect recovery using simulated hardware.


## Latency handoff — 2026-10-23

Read-only review and Core Audio property probe completed. Physical RTL, recording offset and long-duration dropout measurements remain unperformed. No buffer/rate/driver changes were made for this investigation. The full stage plan, acceptance gates, rollback workflow and blank run record are in `Docs/LATENCY-PLAN.md` and `Docs/LATENCY-RUN-TEMPLATE.md`; observations are in `Docs/LATENCY-REVIEW-2026-10-23.md`. The read-only probe source is retained in `Tools/latency-probe.cpp`. Source checksums identify the reviewed code, not the installed driver binary. No optimization or scheduled continuation is in progress.

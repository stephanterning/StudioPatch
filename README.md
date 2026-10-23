# StudioPatch — utvecklarprototyp 0.1

## Open-source repository

StudioPatch is an experimental macOS virtual audio device and routing control panel. The original StudioPatch code is available under the [MIT license](LICENSE). Vendored libASPL and its Apple-derived portions retain their [upstream licenses](Vendor/libASPL/LICENSE), [Apple 2012 notice](Vendor/libASPL/LICENSE.apple2012) and [Apple 2020 notice](Vendor/libASPL/LICENSE.apple2020).

For development, use macOS 14 or later, Xcode with its command-line tools, CMake and Python 3. Provide your own certificate-backed signing identity via `STUDIOPATCH_SIGNING_IDENTITY` or a local `Scripts/signing-identity.txt` file. That file, build products and private keys are excluded from Git.

From the repository root:

```sh
export STUDIOPATCH_SIGNING_IDENTITY="Apple Development: Your Name (IDENTIFIER)"
export STUDIOPATCH_BUILD_DIR="$PWD/build"
bash Scripts/build.sh
bash Scripts/test-runtime.sh
```

Build products are written to `Dist/`. Building does not install the driver or restart audio services. Read [BACKGROUND-RUNTIME.md](BACKGROUND-RUNTIME.md) before installation and [Docs/LATENCY-PLAN.md](Docs/LATENCY-PLAN.md) before latency work. The historical development notes below include superseded behavior; the handoff notice identifies those limitations.


> **Aktuell överlämning, 2026-10-23:** [Plan för latensarbetet](Docs/LATENCY-PLAN.md), [baslinjeanalys](Docs/LATENCY-REVIEW-2026-10-23.md) och [mätprotokoll](Docs/LATENCY-RUN-TEMPLATE.md). Latensoptimering och fysisk loopbackmätning har inte påbörjats. Arbetet återupptas först på användarens begäran.
>
> **Historikvarning:** Flera avsnitt nedan beskriver äldre prototyper och är inte aktuella handhavandeinstruktioner. Nu körs routingen automatiskt i en bakgrundstjänst; appen är en kontrollpanel. Det finns individuella synklås, inbyggda namngivna presets och beständig aktiv preset med osparade ändringar. App och tjänst certifikatsigneras. Manuell Start/Stop, filbaserade presetknappar, global Följ klockmaster och automatisk ad hoc-signering gäller inte längre. Se den nya planens avsnitt om nuläge, byggning och återställning innan fortsatt arbete.

En lokal macOS-app och en virtuell Core Audio-drivrutin för fritt ordnade kanaler från flera ljudkort. Avsedd för UFX III (inklusive dess MADI-kanaler från M-1610 Pro) och ZED-R16.

**Status: byggbar prototyp, inte en verifierad ersättare för RME-drivrutinen.** Ljudlogik och kanalmodell testas i process. Laddning i Core Audio, drift med Ableton och fysisk tur-och-returlatens återstår att verifiera. Inget ljud spelas upp när appen öppnas. Vid första starten är alla rutter frånkopplade; senare starter återställer den senaste sessionen.

## Vad som är implementerat

- En synlig enhet, `StudioPatch`, med oberoende antal in- och utgångar: 0–128 per riktning, minst en riktning aktiv. Exempel: 37 in/21 ut, utan utfyllnad till en tvåpotens.
- Valda kort som försvinner finns kvar utgråade i kortlistan och matrisen. Namn, samtliga kanaler och etiketter hämtas från den senast sparade inventeringen, även efter omstart och i exporterade presets. Befintliga kopplingar kan tas bort, men nya kopplingar till/från kortet blockeras i både matris och kanallista. Kryssrutan går fortfarande att avmarkera. När samma enhets-UID återkommer används dess aktuella kanaler och normal redigering återaktiveras. Listan uppdateras automatiskt varannan sekund när routingen är stoppad. Äldre presets utan sparad kanalinformation måste öppnas med kortet tillgängligt en gång för att få denna information; okända kort visas annars med UID och statusen att kanalinformation saknas.
- Avmarkering av ett ljudkort med sparade in- eller utkopplingar kräver bekräftelse. Varningen visar kortets namn och omfattar även vilande kopplingar. **Avbryt** lämnar kort och routing oförändrade; **Koppla bort** tar bort kortet och dess kopplingar. Kort utan kopplingar avmarkeras direkt.
- Den virtuella enhetens kanalnamn i Core Audio är den härledda etiketten, exempelvis `RE-201`. Utan anslutning används `To Computer N` respektive `From Computer N`. Saknas egen hårdvaruetikett används hårdvarans kanalnamn; flera destinationers namn sammanfogas. Appen publicerar ändringar automatiskt efter kort fördröjning och vid tillämpning/start. Namnändringar skickas separat från ljudkonfigurationen, med Core Audio-notiser, och kräver ingen omstart av enheten. Vid ännu ej tillämpat kanalantal väntar namnpubliceringen tills layouten matchar. Namnen sparas även i drivrutinens beständiga lagring. Detta kräver det nya drivrutinsbygget; faktisk visning och uppdatering i Ableton återstår att verifiera.
- Två oberoende ljudvägar och två matriser: hårdvaruingång → To Computer respektive From Computer → hårdvaruutgång. Ingen automatisk loopback mellan From Computer och To Computer.
- En källa per destination, valfri förgrening till flera destinationer. Ingen summering, gain eller DSP i denna version.
- Matrisens rubriker är låsta som i ”Lås fönsterrutor”: radnamnen stannar till vänster vid sidscrollning, och kolumnnamnen ligger kvar överst vid vertikal scrollning. Varje rubrik följer sina rutor längs den andra axeln. Det gäller båda routingriktningarna, inklusive egna etiketter.
- Riktiga kanalnamn hämtas från drivrutinerna, bland annat UFX Analog, Mic, AES, ADAT och MADI. UI och preset-filer använder kanalnummer från **1**.
- När muspekaren ligger över en ruta markeras dess rad och kolumn, inklusive kanalrubrikerna. Rutan får en tydlig ram. Markeringen ändrar inga kopplingar.
- Dubbelklicka på en hårdvarurubrik för att öppna **Etiketter…**, scrolla till kanalen och fokusera dess etikettfält. På To Computer/From Computer öppnas den anslutna hårdvarukanalen; vid flera destinationer öppnas den första i kortens kanalordning. Utan anslutning öppnas ingen redigerare.
- **Etiketter…** öppnar en redigerare för egna etiketter på hårdvarans in- och utgångar. To Computer och From Computer kan inte ha egna etiketter: de härleds från anslutna hårdvarukanaler och uppdateras när routing eller hårdvaruetikett ändras. Om etikett saknas används hårdvarans kanalnamn. Flera destinationers namn sammanfogas, med identiska namn visade en gång. Äldre egna etiketter på virtuella kanaler ignoreras. I matrisen visas etiketten på en separat cyanblå rad under originalnamnet. Etiketten kompletterar kortets namn och kanalnamn i matris och kanallista, exempelvis `UFX III · Analog 9 — Sångmikrofon`. Etiketter sparas per enhets-UID, riktning och kanal, även utan routing eller när kanalen inte används. De ingår i automatisk sessionssparning och exporterade presets. Töm textfältet för att ta bort en etikett. Hårdvarans originalnamn ändras inte. StudioPatch-enhetens exponerade kanalnamn härleds däremot från dessa etiketter och routingen.
- Enhetskopplingar sparas med Core Audio UID, inte tillfälligt enhetsnummer. JSON-presets kan öppnas och sparas.
- Varje ändring sparas automatiskt i `~/Library/Application Support/StudioPatch/last-session.json` med atomisk filersättning. Kanalantal, hela routingen inklusive vilande kopplingar, valda kort, klockmaster och buffert-/frekvensval återställs vid nästa start. Även 0/0 kan sparas som redigeringsläge, men kan inte startas som ljudenhet. En tom kortlista eller tillfälligt saknade kort ersätts inte av standardval vid återställning. Routing startar inte automatiskt. Sparfel visas i appen; en oläsbar sessionsfil säkerhetskopieras innan den ersätts efter nästa ändring. **Spara preset…** finns kvar för egna namngivna presets.
- I båda riktningarna får en källa gå till flera destinationer. Varje destination får högst en källa; ett nytt val ersätter dess tidigare koppling. Ingen summering eller mixning görs. Presets med flera källor till samma destination avvisas, även om någon av kopplingarna är vilande.
- Kanalantal och sparad routing hanteras separat. När antalet exponerade kanaler minskas blir deras kopplingar vilande: de skickas inte till ljudmotorn och ger inget ljud. När kanalantalet ökas återkommer kopplingarna, även efter att en preset sparats och öppnats. Kanallistan markerar vilande utgångskopplingar. Ett uttryckligt val av en ny koppling eller ”Ej ansluten” ersätter den tidigare kopplingen till samma destination.
- Ändring av kanalantal/frekvens avvisas medan den virtuella enheten används. Stoppa routingen och avaktivera DAW-ljudmotorn först.
- En privat Aggregate Device för ljudmotorn. Användarens befintliga Aggregate Device och standardenheter ändras inte av appen.
- Följ klockmaster: övervakar masterns frekvens och synkar automatiskt övriga valda fysiska kort vid avvikelse, även utan installerad virtuell drivrutin. Mastern ändras aldrig. Efter ett misslyckat försök görs tre direkta återförsök; därefter väntar appen fem sekunder mellan varje försök. Status visas i sidopanelen. Avmarkering stoppar fortsatta försök; ett redan påbörjat drivrutinsanrop kan behöva avslutas. Byte av master eller korturval startar en ny försöksserie. Pågående routing stoppas före synkning och återstartas inte automatiskt.
- Saknad kanal eller misslyckad frekvenssynkning blockerar start. Enhets-/formatändring under drift tystar utgångarna och stoppar routingen vid nästa statuskontroll.

## Arkitektur och latens

```text
UFX / ZED ingångar → privat Core Audio-aggregate → routingmotor
    → intern dold bryggutgång → capture-tidsbuffert → StudioPatch input → Ableton

Ableton → StudioPatch output → playback-tidsbuffert
    → intern dold bryggingång → routingmotor → UFX / ZED uppspelningskanaler
```

Drivrutinen är ett AudioServerPlugIn byggt med libASPL. Den dolda bryggan och den synliga enheten delar tidsbas, men capture och playback har separata buffertar. Därför kan kanalantalen skilja sig och uppspelning blandas inte automatiskt in i inspelningen. Ingen fil-, nätverks- eller IPC-ljudtransport används mellan app och drivrutin; Core Audio transporterar ljudet via den interna bryggan.

Denna prototyp prioriterar korrekt kanalmodell och säkert beteende framför lägsta möjliga latens. Ljudcallbackarna allokerar inte minne och väntar inte på mutexar. Tidsbuffertarna använder atomiska samples och returnerar tystnad vid saknade eller överskrivna frames. Buffertar berörs vid initiering men minnessidor är ännu inte låsta; produktionshärdning återstår.

Transportmarginalen är automatisk som standard och följer vald I/O-buffert med fyra buffertar **per riktning**. Aktuella samples och millisekunder per riktning visas vid vald samplingsfrekvens. Under **Avancerat** kan automatiken stängas av och marginalen väljas manuellt; det manuella värdet bevaras när automatiken används. Äldre sessioner utan inställningen använder automatiken. Standard är 96 kHz, 64 samples I/O och därmed 256 samples marginal, med UFX III förvald som master när kortet finns. Vid 96 kHz motsvarar transportmarginalerna tillsammans 5,33 ms, **utöver** andra delar av signalvägen. Det är en beräkning av den valda marginalen, inte uppmätt tur-och-returlatens. UI tillåter lägre marginaler; start kräver minst två faktiska I/O-buffertar per riktning. Exempel: 32 samples I/O och 64 samples marginal ger 1,33 ms beräknad sammanlagd transportmarginal vid 96 kHz. Stabiliteten i det läget är inte verifierad.

UFX och ZED kan använda gemensam ADAT-klocka med driftkompensation av på de fysiska korten. Den virtuella bryggan använder i denna version datorns tidsbas och har Core Audios driftkompensation på. **Prototypen är därför inte garanterat bittransparent och är inte en drivrutin direkt klockad av UFX.** En senare optimering kan knyta den virtuella klockan till hårdvarans tidsstämplar; det behöver implementeras och mätas separat.

Drivrutinen rapporterar sin egen transportmarginal, men förmedlar ännu inte all bakomliggande hårdvaru-/aggregate-latens till DAW:n. Automatisk inspelningskompensation kan därför bli fel. Använd den inte för tidskritiska inspelningar förrän en fysisk loopbackmätning och kontroll av inspelningsoffset har gjorts.

## Bygg och öppna

Kräver Xcode/Command Line Tools, CMake och macOS 14 eller senare. Det medföljande bygget är för Apple Silicon på denna Mac.

```sh
./Scripts/build.sh
open Dist/StudioPatch.app
```

Bygget skapar app, `.driver` och det skrivskyddade verktyget `patch-inspect` i `Dist`. Det installerar ingenting. Utan drivrutin går det att inventera ljudkort, redigera matriser och spara presets; knappar för ljudstart är avstängda.

Bygget använder lokal ad hoc-signering om `STUDIOPATCH_SIGNING_IDENTITY` inte är satt. Det är inte notariserat. Att signaturkontrollen passerar bevisar inte att Core Audio laddar drivrutinen. Ändra inte SIP eller macOS säkerhetsinställningar för att kringgå ett eventuellt laddningsfel; undersök i stället loggar och signering.

## Installation och första hårdvarutest — ännu inte utfört

1. Stäng ljudprogram och spara pågående arbete.
2. Granska `Scripts/install-driver.sh`. Det installerar endast `StudioPatch.driver` i `/Library/Audio/Plug-Ins/HAL` och vägrar skriva över en befintlig installation. För uppdatering: använd `sudo ./Scripts/install-driver.sh --replace`; den gamla StudioPatch-drivrutinen sparas då under `/Library/Audio/StudioPatch Backups` före ersättning. Starta om datorn efter uppdateringen.
3. Kör `sudo ./Scripts/install-driver.sh` och starta därefter om datorn. Skriptet startar inte om ljudservern automatiskt.
4. Kontrollera att **StudioPatch** syns i Ljud-/MIDI-inställningar. Öppna appen. Bekräfta att båda fysiska korten visar rätt frekvens och att ADAT verkligen är låst/synkroniserad. Appen kan inte verifiera ADAT-låsningen åt dig.
5. Ange önskat antal in/ut och frekvens. Klicka **Tillämpa kanalantal** medan DAW-ljudmotorn är av. Välj sedan StudioPatch som både in- och utenhet i Ableton. Vid kanaländring kan Abletons Input/Output Config behöva uppdateras.
6. Välj båda korten, rätt klockmaster och dina rutter. Låt driftkompensation vara av på ADAT-synkade kort. Med **Följ klockmaster** läses masterns frekvens och övriga valda kort ställs till samma frekvens. Appen kontrollerar först stöd, skrivbehörighet och om kortet används av ett annat program. Ett asynkront byte måste bekräftas inom två sekunder per kort. Det finns ingen manuell synkknapp; avvikelser upptäcks vid inventeringen varannan sekund och synkningen körs i bakgrunden. Kontrollera kanalvalen efter bytet: vissa kanaler kan försvinna vid högre frekvens. Vid delvis misslyckat byte kan något kort redan ha bytt frekvens; detta visas som ett fel och ingen automatisk återställning görs. Klockkällan och ADAT-låsningen ändras inte av appen.
7. Börja med en enda signal på låg nivå och större transportmarginal. Ge mikrofonbehörighet om macOS frågar. Klicka **Starta routing**. Ingen startsignal genereras av appen.
8. Testa inspelning och uppspelning var för sig, därefter samtidigt. Kontrollera att uppspelning inte hörs på inspelningskanalerna utan avsiktlig extern routing.
9. Mät en fysisk ut→in-loopback både med direkt RME och StudioPatch, vid samma frekvens och buffert. Skillnaden är det relevanta måttet på extra latens. Kontrollera även DAW:ns inspelningsoffset.
10. Minska marginal och buffert stegvis; kör sedan minst 30 minuter, kontrollera glitchar, frånkoppling, stopp/start och återöppning av Ableton.

UFX-utgångar i appen är dess **software playback-kanaler**. Hur de når fysiska uttag styrs fortfarande av TotalMix. ZED:s returval styrs också av mixerns egna inställningar.

Avinstallation: stäng ljudprogram, kör `sudo ./Scripts/uninstall-driver.sh`, starta om datorn. Skriptet tar bara bort en bundle vars identifierare är `se.studiopatch.driver`.

## Tester och kvarvarande arbete

`core-tests` täcker asymmetriskt kanalantal, formatvalidering, duplex-isolering, exakt tidsbuffertförskjutning, tystnad vid saknade/stale frames, gemensam virtuell tidsbas, aktiv klient vid omkonfiguration och samtidig läsning/skrivning över buffertomslag.

`route-tests` använder den riktiga motorcallbacken med syntetiska UFX-, ZED- och bryggbuffertar för att kontrollera omordning, båda riktningar, tysta oanvända utgångar och att ändrad layout tystas.

`rate-tests` täcker att mastern aldrig skrivs, fördröjd bekräftelse, redan synkade kort, avvisning av upptagna/skrivskyddade/inkompatibla kort, timeout och ändrad master under synkning. Tester använder simulerade drivrutinsanrop. Verkliga frekvensbyten på UFX/ZED är ännu inte testade. Ändring under pågående ljud stoppar fortfarande routingen; automatisk synkning försöker därefter följa mastern.

`preset-tests` testar appens faktiska Swift-modell: minskning av in/ut oberoende av varandra, sparning/öppning med vilande kopplingar, återökning, noll kanaler i ena riktningen, uttrycklig bortkoppling och äldre preset-format. Motorns JSON får endast aktiva kopplingar. `route-tests` kontrollerar dessutom att borttagna aktiva rutter tystas utan kvarvarande samples och kan återaktiveras i båda riktningar.

Kvar före skarp användning: verklig HAL-laddning/omkonfiguration, signerad distribution, mikrofonbehörighet, verifiering av privat aggregate med den dolda bryggan, enhetsbyte och viloläge, långtidstest, mätning av RTL/DAW-kompensation och prestanda vid många kanaler. Appen måste vara öppen under routing. Routing kan ändras efter stopp; ändring under pågående ljud är inte implementerad.

## Källor och licenser

- libASPL är versionslåst till `633e0f70203edd87d320fc5a3cae901e1363aac5` och levereras oförändrat i `Vendor/libASPL`. Bibliotekets MIT- och Apple-licenser finns där.
- [libASPL](https://github.com/gavv/libASPL)
- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Aggregate-egenskaper och kanalordning följer dokumentationen i Xcodes `CoreAudio/AudioHardware.h`.

Den medföljande källkoden är lokal och installerar inga tjänster eller schemalagda uppgifter.

## Testversion med bakgrundsmotor

Stäng den äldre StudioPatch-appen och ljudprogrammen före uppdateringen. Installera den nya drivrutinen med `sudo Scripts/install-driver.sh --replace`. Kör därefter `Scripts/install-service.sh` som din vanliga användare, utan sudo. Starta om datorn. Tjänsten startar vid inloggning med sparad konfiguration; appen kan öppnas och stängas som kontrollpanel.

Routing och kanalantal tillämpas automatiskt, med ett möjligt kort ljudavbrott. Frekvenser som StudioPatch exponerar hämtas från klockmastern (inom 8–384 kHz). Ändra frekvens i Ableton för att begära byte på de valda korten. Vid avslag eller timeout blir transporten tyst och felet visas i panelen; tillåt systemnotiser om du också vill få dem. Faktisk kompatibilitet med klienters formatbyten måste verifieras med den installerade testdrivrutinen.

Bakgrundstjänsten kan avregistreras med `launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/se.studiopatch.runtime.plist"`. Ta därefter bort just den plist-filen för att stänga av start vid inloggning. Appen startar tjänsten igen när den öppnas.

### Lokal signering

Bygget använder certifikatfingeravtrycket i `Scripts/signing-identity.txt` och kräver att dess privata nyckel finns i användarens nyckelring. På en annan utvecklingsdator anger du `STUDIOPATCH_SIGNING_IDENTITY` eller uppdaterar fingeravtrycket. Ingen privat nyckel ingår i projektet. Appen och den inbäddade motorn använder samma certifikat och signeringsidentifierare (`se.studiopatch.app`) för gemensam behörighetsidentitet. Bygget faller inte automatiskt tillbaka till ad hoc-signering. Första övergången från äldre lokala byggen kan kräva ett nytt godkännande för ljudåtkomst.

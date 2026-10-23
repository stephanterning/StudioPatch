# Bakgrundsmotor och kontrollpanel

Status: implementerad testversion. StudioPatchService kör motorn i en separat process, med processlås mot dubbla instanser. Kontrollpanelen är ensam skrivare till den atomiska sessionsfilen; tjänsten läser önskad konfiguration och skriver en separat tidsstämplad statusfil. Tjänsten kan registreras med Scripts/install-service.sh för start vid inloggning och återstart efter krasch. Ingen ny drivrutin eller tjänst har installerats automatiskt.

Nuvarande avvägning: även rena routingändringar gör en automatiskt samordnad omstart av transporten, vilket kan ge ett kort ljudavbrott. Låsfria routingbyten på en blocksgräns är inte implementerade. Kanalantal byts genom HAL-konfiguration på befintliga enhetsobjekt; strömmarna återskapas. Varje ändring använder en ny gemensam ring/tidsbas och håller ljudet tyst tills båda ändpunkterna är klara. Den virtuella drivrutinens stödda frekvensområde är 8–384 kHz; masterintervall begränsas till detta område.

Verifierat: sex testsamlingar samt separat processintegration med simulerad native-backend. Integrationen täcker automatisk start utan panel, singleton, ändrad routing, tystnad vid fel, återhämtning och frekvensbegäran. Kärntestet täcker formatbyte med aktiv kontrollhandler, bevarat enhets-ID, nya strömbredder, 192 kHz, publicerade format och tystnad i övergången. Den rena C++-policyn RuntimePolicy är ett referenstest; tjänstens verkliga orkestrering ligger i Swift Model.runtimeTick och testas separat. Faktisk HAL/Ableton-interaktion, systemnotiser och inloggningsstart återstår att verifiera efter installation.

## Avsett beteende och fortsatta krav

En separat per-användartjänst äger hårdvarans I/O och startar automatiskt med den sparade konfigurationen. Kontrollpanelen skickar versionsnumrerade konfigurationsönskemål och läser status via lokal IPC. Stängning eller avslut av kontrollpanelen får inte stoppa ljudet. Tjänsten måste vara singleton; återanslutning får inte skapa dubbla aggregat. Inställningsfilen ska ha en ensam skrivare, inte konkurrerande app- och tjänsteprocesser.

Routingsnapshot byts på en ljudblocksgräns. Kanalantal/format byts via HAL:s RequestDeviceConfigurationChange/PerformDeviceConfigurationChange. Den synliga enhetens identitet ska bevaras. Den interna bryggan och den synliga enheten måste samordnas; inga callbackar får använda det nya antalet kanaler mot gamla buffertar. Ingen kontrollkod, fil-I/O, IPC eller allokering får köras i ljudcallbacken. Gamla snapshots frigörs först när callbacken lämnat dem.

Masterkortets rapporterade AvailableNominalSampleRates läses och publiceras som tillgängliga frekvenser på StudioPatch. Tjänsten måste klara alla frekvenser som publiceras, inklusive ändrat ADAT/MADI-kanalantal. Om ett annat valt kort inte stöder en masterfrekvens ska den begärda övergången ge tystnad och status, inte ett falskt lyckat resultat.

En begäran från Ableton har en generation och en önskad frekvens. Tjänsten tystar transporten, begär masterbytet, inväntar bekräftad masterfrekvens, synkar övriga kort och inventerar om kanalformaten. Ljud återupptas endast när alla deltagare och den virtuella enheten har bekräftat samma frekvens och format. Ett gammalt hårdvaruvärde under övergången får inte skriva över klientens begäran. Nyare önskemål ersätter äldre. Frånkoppling och misslyckande lämnar motorn tyst. Första försöket följs av tre direkta återförsök och därefter fem sekunder mellan försöken.

Fel visas bestående i kontrollpanelen. Systemnotiser är valfria, behöver macOS tillstånd och ska dedupliceras per felövergång; inte en notis per återförsök. Nekat notistillstånd får aldrig hindra ljudmotorn.

## Verifiering före leverans

- Separat process: ljud fortsätter när kontrollpanelen stängs och avslutas; återöppning återansluter utan ljudavbrott.
- Routing: en-till-flera, aldrig mixning; inaktiva kanaler bevarar kopplingar men förblir tysta.
- Format: klient ansluten under ökning/minskning, båda riktningar inklusive noll kanaler i ena riktningen; objektidentitet och kanalnamn bevaras korrekt.
- Frekvens: 48/96/192 kHz i båda riktningar där mastern stöder det; avslag, timeout, delvis lyckad gruppsynk, ny begäran under pågående byte, frånkoppling och återanslutning.
- Realtime: inga gamla ringdata efter misslyckande/återhämtning, inga race vid snapshotbyte, inga notifieringsdeadlocks.
- Regression: befintliga fem testsamlingar samt RuntimePolicyTests. Därefter faktisk HAL/Ableton-verifiering efter uttrycklig drivrutinsinstallation.

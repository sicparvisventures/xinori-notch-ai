# Xinori Notch AI — analyse en implementatieplan

> Werkdocument, Nederlands. De code, comments en README blijven Engels; dit is een
> beslisdocument, geen contributor-documentatie.
>
> Alles onder "geverifieerd" is op deze machine gemeten, niet aangenomen.
> macOS 26.5.2 · MacBook Pro M5 · 4 augustus 2026.

---

## 1. Waar we staan

De app werkt: klikken op de notch, typen of praten, en een lokaal model dat via
zestien tools je Mac uitleest en met goedkeuring aanpast. Wat er nog niet is, is
*bereik* en *geheugen*. Het model kan je mail lezen maar niet je berichten, je
agenda maar niet je notities, je bestanden maar niet wat je er vorige week over
zei. Elke vraag begint bij nul.

Dit document beantwoordt vier vragen:

1. Wat kan een app op macOS 26 überhaupt aan een model geven?
2. Welke daarvan ontbreken nu, en wat kosten ze?
3. Hoe bouw je er geheugen omheen zonder de privacybelofte te breken?
4. Waar hoort de app te leven als je geen notch hebt?

---

## 2. Wat de Mac écht kan blootgeven

Dit is de kern van de analyse. Ik heb elke bron op deze machine geprobeerd in
plaats van de documentatie te geloven — de mailtool leerde ons al dat AppleScript
en werkelijkheid uiteen kunnen lopen.

### Geverifieerd leesbaar

| Bron | Pad / API | Gemeten | Toegang |
|---|---|---|---|
| **Mail** | `~/Library/Mail/V10/…/Envelope Index` | 31.559 ongelezen | Volledige Schijftoegang |
| **Notities** | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | **1.564 notities**, bodies uitpakbaar | Volledige Schijftoegang |
| **Berichten** | `~/Library/Messages/chat.db` | **231.081 berichten** | Volledige Schijftoegang |
| **Safari-geschiedenis** | `~/Library/Safari/History.db` | **4.394 items** | Volledige Schijftoegang |
| **Foto's** | `~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite` | **31.052 assets** | Volledige Schijftoegang |
| **Contacten** | `~/Library/Application Support/AddressBook` | map aanwezig | Contacts-toestemming |
| **Agenda** | EventKit | werkt al | Agenda-toestemming |
| **Shortcuts** | `shortcuts` CLI | werkt — *Open App*, *GPT*, *ASK CHATGPT* | geen |
| **Systeem** | `system_profiler`, `pmset`, `df` | werkt al | geen |
| **Spotlight** | `mdfind` | werkt al | geen |

### De belangrijkste vondst: notities zijn bruikbaar

De bodies zitten als **gzip-verpakte protobuf** in `ZICNOTEDATA.ZDATA`. Uitpakken
en de leesbare tekstruns eruit halen werkt:

```
uitgepakt: 24.590 bytes
leesbaar:  "Everyone at pj70 Copy started modal onboarding Who sees what
            Private groups - private group dms …"
```

Dat is precies wat een second brain nodig heeft: 1.564 stukken context die jij
zelf al hebt geschreven, zonder dat er iets nieuws bijgehouden hoeft te worden.

### Wat níét kan, en waarom

| Wilde ik | Waarom niet |
|---|---|
| Mail via AppleScript | Mail beantwoordt geen Apple Events op deze machine — `-1712` na 40s. Al opgelost via de index. |
| Herinneringen via SQLite | Pad bestaat niet meer op macOS 26; **EventKit** dekt dit wel (`EKReminder`) |
| Schermafbeeldingen | Vereist Schermopname-toestemming; wél haalbaar, maar een eigen ontwerpvraag (zie §8) |
| Wachtwoorden | Keychain van de gebruiker is bewust onbereikbaar. Blijft zo. |

---

## 3. De tool-gap

Zestien tools nu. De analyse hieronder is geordend op *waarde per euro aan
complexiteit*, niet op wat leuk is om te bouwen.

### Hoge waarde, lage complexiteit

| Tool | Wat het oplost | Basis |
|---|---|---|
| `list_notes` / `read_note` | "wat schreef ik ook alweer over X" | NoteStore.sqlite, geverifieerd |
| `create_note` | korte notities dicteren zonder Notes te openen | AppleScript naar Notes (schrijven wél, lezen te traag) |
| `search_messages` | "wat zei Maarten over die levering" | chat.db, 231k berichten |
| `list_reminders` / `create_reminder` | takenlijst | EventKit, zelfde als agenda |
| `list_contacts` | "het nummer van de accountant" | Contacts-framework |
| `run_shortcut` | **elke Shortcut wordt een tool** | `shortcuts run`, CLI werkt |
| `browser_history` | "die pagina van gisteren" | History.db |
| `clipboard_read` / `write` | tekst doorgeven zonder plakken | NSPasteboard |
| `window_list` | "wat staat er open" | CGWindowList, al eens gebruikt |

`run_shortcut` verdient een aparte streep. Het maakt de toolset **oneindig
uitbreidbaar zonder code**: alles wat de gebruiker in Shortcuts kan bouwen, kan
het model aanroepen. Dat is een betere oplossing voor "laat de AI zelf tools
maken" dan een `create_tool` die shell-sjablonen wegschrijft — de grens blijft
waar hij hoort, want de gebruiker heeft de Shortcut zelf gemaakt.

### Hoge waarde, hogere complexiteit

| Tool | Waarom lastiger |
|---|---|
| `screenshot` + visie | Vraagt Schermopname-toestemming én een vision-model; qwen3:8b kan het niet |
| `edit_spreadsheet` | Lezen kan al; schrijven vraagt openpyxl en een goede diff-strategie |
| `app_action` via Accessibility | Krachtig maar fragiel; AXSwift is de gebaande weg |

### Wat ik bewust níét zou bouwen

- **`delete_permanently`.** De prullenmand is de grens. Er is geen scenario waar
  een model definitief moet kunnen wissen.
- **`send_mail` dat echt verstuurt.** `compose_mail` opent een venster, jij drukt
  op verzenden. Dat blijft zo.
- **Toegang tot Foto's-inhoud.** 31.052 assets is technisch leesbaar, maar de
  privacy-afweging is een ander gesprek dan "lees mijn agenda".

---

## 4. De agent-architectuur

Dit is het onderwerp waar de rest aan hangt. Zodra er dertig tools zijn, is
"geef alles mee aan één model" geen optie meer — niet omdat het niet past, maar
omdat de keuze verslechtert.

### 4.1 Waarom "alle tools meegeven" breekt

Elk toolschema kost context, en belangrijker: elke extra optie verhoogt de kans
dat het model de verkeerde pakt. Met zestien tools zien we dat al — bij een vraag
over Excel-bestanden koos qwen3:8b `list_directory` op één map in plaats van
`search_files` over de schijf.

De voor de hand liggende oplossing is tool-search: embed alle toolbeschrijvingen,
haal de top-5 op bij een vraag, geef alleen die mee.

**Dat werkt minder goed dan het klinkt.** De ACL-2025-paper
[*Retrieval Models Aren't Tool-Savvy*](https://github.com/mangopy/tool-retrieval-benchmark)
(ToolRet) benchmarkt precies dit en laat zien dat generieke IR-modellen
structureel ondermaats presteren op tool-retrieval — ze zijn getraind op
documenten, niet op API-beschrijvingen waar de match vaak op parameters zit en
niet op woorden. Er is een apart trainingscorpus voor nodig om ze bruikbaar te
maken.

Dat is een reden om **niet** op vectorzoeken te leunen als primaire routering.

### 4.2 Wat wél werkt: domeinen in plaats van vectoren

Groepeer tools per domein en laat het model eerst een *domein* kiezen. De
orchestrator ziet dan geen dertig tools maar zes:

| Specialist | Tools | Model |
|---|---|---|
| `mail` | list_mail, search_messages, compose_mail | snel |
| `agenda` | list_calendar, create_calendar_event, herinneringen | snel |
| `bestanden` | search_files, list_directory, read_file, read_spreadsheet, write_file, move_to_trash | snel |
| `systeem` | system_info, list_apps, control_app, schedule_job, run_shell | midden |
| `geheugen` | search_memory, search_notes, create_note, remember | midden |
| `shortcuts` | list_shortcuts, run_shortcut | snel |

Zes keuzes in plaats van dertig, en de keuze is semantisch veel makkelijker:
"gaat dit over mail?" is een vraag die een 4B-model betrouwbaar beantwoordt,
"is `search_files` beter dan `list_directory` hier?" niet.

De domeinindeling is meteen ook de subagent-indeling. Dat is geen toeval — het is
dezelfde vraag, één keer beantwoord.

### 4.3 De drie snelheden

Niet elke vraag verdient dezelfde machinerie. Dit is wat
[RouteLLM](https://github.com/lm-sys/RouteLLM) laat zien voor modelkeuze —
eenvoudige vragen naar een goedkoper model levert tot 85% kostenreductie met 95%
van de kwaliteit — toegepast op orkestratie in plaats van op modellen.

```
vraag
  │
  ├─ 1. DIRECT      geen tools nodig ("wat is 12% van 4500")
  │                 → klein model, één beurt, klaar
  │
  ├─ 2. ENKELVOUDIG één domein ("hoeveel batterij heb ik")
  │                 → orchestrator laadt dat ene domein, roept zelf aan
  │
  └─ 3. GEDELEGEERD meerdere domeinen of meerdere stappen
                    ("vat mijn mail samen en zet de deadlines in mijn agenda")
                    → specialisten parallel, orchestrator vat samen
```

De router die dit bepaalt hoeft geen apart model te zijn. De orchestrator krijgt
de zes delegate-tools plus een instructie: *antwoord direct als je het weet,
gebruik één domein als het over één ding gaat, delegeer alleen bij meerdere.*
Dat is één beurt van een 8B-model — goedkoper dan een aparte classificatiestap
en makkelijker te debuggen.

### 4.4 Hoe een specialist eruitziet

Elke specialist is dezelfde `ChatModel`-lus, maar met drie dingen anders:

```swift
struct Specialist {
    let name: String            // "mail"
    let systemPrompt: String    // smal, alleen zijn eigen domein
    let tools: [any Tool]       // zijn eigen deelverzameling
    let model: ModelTier        // .fast | .balanced
    let maxRounds: Int          // 3, niet 6 — een specialist dwaalt niet af
}
```

De orchestrator roept ze aan als tools:

```
delegate_mail(task: "zoek alles van de boekhouder over Q2")
  → specialist draait eigen lus met eigen tools
  → geeft één samenvatting terug, geen ruwe uitvoer
```

Dat laatste is het belangrijkste ontwerpdetail. **Een specialist rapporteert een
samenvatting, nooit zijn ruwe toolresultaten.** Anders verplaats je het
contextprobleem alleen maar: 31.559 mailregels in de subagent zijn prima, diezelfde
regels teruggeven aan de orchestrator is dat niet.

[`pi-subagents`](https://github.com/nicobailon/pi-subagents) noemt precies dit als
zijn kernproblemen — *truncation, artifacts, session sharing*. Concreet voor ons:

- **Afkappen.** Een specialist mag maximaal ~1.500 tekens teruggeven. Meer dan dat
  betekent dat hij niet heeft samengevat.
- **Artefacten.** Grote resultaten (een volledige spreadsheet) krijgen een id en
  blijven bij de specialist; de orchestrator vraagt ze op als hij ze nodig heeft.
- **Context delen.** Een specialist krijgt de *taak*, niet het hele gesprek. Dat
  scheelt tokens en voorkomt dat hij zich met andermans werk bemoeit.

### 4.5 Modellen per rol

[Maestro](https://github.com/Doriandarko/maestro) doet dit al expliciet met
`ORCHESTRATOR_MODEL`, `SUB_AGENT_MODEL` en `REFINER_MODEL` als losse instellingen.
Wij hebben dezelfde drie rollen en dezelfde vrijheid, plus de mogelijkheid om
lokaal en cloud te mengen:

| Rol | Standaard | Waarom |
|---|---|---|
| Router / orchestrator | `qwen3:8b` | Oordeel nodig; moet begrijpen wat een vraag ómvat |
| Specialist | `qwen3:4b` | Smal domein, drie tools — 4B is hier genoeg en twee keer zo snel |
| Samenvatter | orchestrator hergebruiken | Aparte beurt, geen apart model |
| Directe route | `qwen3:4b` | Geen tools, alleen taal |

In instellingen wordt dit per rol instelbaar. Iemand met een Anthropic-sleutel kan
de orchestrator op `claude-opus-5` zetten en de specialisten lokaal laten — dat is
precies de mix waar deze architectuur goed in is: het dure model doet het denkwerk,
de goedkope doen het graafwerk, en je mail gaat nooit naar de cloud.

### 4.6 Wat dit kost

Eerlijk zijn over de keerzijde:

- **Meer beurten.** Een gedelegeerde vraag is minimaal drie modelaanroepen
  (router → specialist → samenvatting) waar het er nu één is. Lokaal betekent dat
  seconden, niet centen.
- **Meer plekken waar het misgaat.** Een specialist die zijn taak verkeerd begrijpt
  faalt stiller dan een tool die een fout teruggeeft.
- **De grendel moet mee.** Een specialist die `run_shell` mag aanroepen moet
  dezelfde goedkeuringsvraag stellen. Dat betekent dat de bevestiging door de
  orchestrator heen naar de UI moet — niet ingewikkeld, wel iets om vanaf het begin
  goed te doen.

Daarom staat de directe route bovenaan: **de meeste vragen horen geen orkestratie
te raken.**


---

## 5. Het second brain

Dit is de grootste van de vier onderwerpen, en degene waar je het makkelijkst
iets bouwt dat indrukwekkend demonstreert en nutteloos is in gebruik.

### Wat het probleem echt is

Je vraagt "wat weet ik over Van Damme?" en het model heeft drie bronnen nodig:
je notities, je mail, en je eerdere gesprekken. Het probleem is niet opslag —
alles staat er al. Het probleem is **ophalen**: 1.564 notities passen niet in een
contextvenster, dus er moet iets kiezen wélke drie relevant zijn.

### Drie lagen, oplopend in ambitie

**Laag 1 — index en zoeken (de basis).**
Eén SQLite-database in `~/Library/Application Support/NotchAI/`, met FTS5
full-text search over notities, mail-onderwerpen en gespreksgeschiedenis. Geen
embeddings, geen graph. Dit alleen al beantwoordt de meeste "wat weet ik over X"
vragen, want mensen zoeken op woorden die ze zelf gebruikt hebben.

Kosten: laag. FTS5 zit in de systeem-SQLite. Bouwtijd: dagen, niet weken.

**Laag 2 — semantisch zoeken.**
FTS5 vindt "Van Damme" maar niet "die aannemer uit Gent". Daarvoor heb je
embeddings nodig. Op Swift is
[`similarity-search-kit`](https://github.com/ZachNagengast/similarity-search-kit)
(533★) de volwassenste optie: on-device embeddings plus vectorzoeken, geen server.
Alternatief is Ollama zelf — die serveert `/api/embeddings` met bijvoorbeeld
`nomic-embed-text`, wat betekent dat je geen tweede runtime hoeft te introduceren.

**Dat laatste is waarschijnlijk de juiste keuze**: Ollama draait toch al, het
model staat toch al resident, en het houdt het aantal bewegende delen laag.

**Laag 3 — de graph.**
Entiteiten (mensen, projecten, bedrijven) en de relaties ertussen, afgeleid uit
je notities. Dit is wat [`graphiti`](https://github.com/getzep/graphiti) (29,5k★)
doet voor agents, en wat
[`memory-mcp-server`](https://github.com/okooo5km/memory-mcp-server) in het klein
doet.

**Mijn advies: nog niet bouwen.** Een graph is duur om te onderhouden — elke
notitie moet door een model om entiteiten te extraheren, en die extractie
verslechtert stilletjes als je model verandert. Laag 1 en 2 leveren 80% van het
gevoel voor 20% van het werk. Bouw de graph pas als je merkt dat semantisch
zoeken tekortschiet op een concrete vraag die je vaak stelt.

### Wat er wél nieuw bijgehouden moet worden

Eén ding kan het systeem niet uit bestaande bronnen halen: **wat jij het verteld
hebt.** Een `remember` tool die korte feiten wegschrijft naar een eigen
markdownmap — met jouw goedkeuring, zichtbaar en verwijderbaar in instellingen —
sluit die lus. Dat is het patroon dat
[`obsidian-second-brain`](https://github.com/eugeniughelbur/obsidian-second-brain)
(3,8k★) gebruikt: platte markdown, geen zwarte doos.

### De privacyafweging, expliciet

Een index van je notities, mail en berichten in één doorzoekbare database is
gevoeliger dan de losse bronnen. Drie regels die daaruit volgen:

1. De index staat in `~/Library/Application Support/NotchAI/`, niet in iCloud.
2. Indexeren is **opt-in per bron**, in instellingen, met een teller die laat
   zien hoeveel er geïndexeerd is.
3. Eén knop die alles wist.

---

## 6. Aanwezigheid in de menubalk

De app is nu `LSUIElement`: geen Dock-icoon, geen menubalk-item. Als hij niet
draait, weet je dat niet. Als hij vastloopt, kun je hem niet herstarten zonder
Terminal.

Dat is een fout die Ollama en Cursor allebei niet maken.

### Wat het moet zijn

Een `NSStatusItem` met het app-icoon en een dropdown die toont:

- **Status** — draait het model, welk model, is Ollama bereikbaar
- **Snelle acties** — paneel openen, nieuw gesprek, dicteren
- **Instellingen** — hetzelfde scherm dat nu in de notch zit
- **Afsluiten** — de ontbrekende knop

De dropdown is een `NSPopover` met SwiftUI erin, zodat instellingen letterlijk
dezelfde view is als in het paneel. Geen tweede implementatie.

`reminders-menubar` (3,9k★) is een goed voorbeeld van deze vorm in SwiftUI.

---

## 7. Zonder notch

Op een Mac zonder notch sluit de app zichzelf nu af. Dat is een harde muur voor
iedereen met een MacBook Air van voor 2022, een Mac mini, of een externe monitor
als hoofdscherm.

### De vorm

Een **zwevende pill** aan de bovenrand van het scherm, midden, die zich gedraagt
als de notch: klein in rust, groeit bij hover, klapt open bij klik. Technisch is
het dezelfde `NSPanel` op hetzelfde niveau — alleen de geometrie verandert, en de
vorm krijgt afgeronde bovenhoeken in plaats van de holle schouders.

`NotchGeometry` moet dus een `Placement` worden:

```swift
enum Placement {
    case notch(NotchGeometry)   // hardware
    case floating(NSScreen)     // pill, zelfde gedrag
}
```

Dat is een kleine wijziging met groot bereik: het verdubbelt de doelgroep en
maakt de app testbaar op elke Mac.

---

## 8. Verwante projecten

Actief gezocht op GitHub. Wat er echt toe doet:

### Direct bruikbaar

| Project | ★ | Waarvoor |
|---|---|---|
| [ZachNagengast/similarity-search-kit](https://github.com/ZachNagengast/similarity-search-kit) | 533 | On-device embeddings + vectorzoeken in Swift |
| [mattt/ollama-swift](https://github.com/mattt/ollama-swift) | 453 | Volwassen Ollama-client mét tool use — onze eigen laag kan slanker |
| [threeplanetssoftware/apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) | 538 | Het protobuf-formaat van Notes, volledig uitgewerkt |
| [tmandry/AXSwift](https://github.com/tmandry/AXSwift) | 413 | Accessibility-wrapper, als we apps willen besturen |

### Als referentie

| Project | ★ | Waarom kijken |
|---|---|---|
| [mattt/iMCP](https://github.com/mattt/iMCP) | 1.510 | Berichten, Contacten, Herinneringen ontsloten — precies onze gap |
| [openclaw/Peekaboo](https://github.com/openclaw/Peekaboo) | 4.956 | Schermafbeeldingen en app-besturing voor agents |
| [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) | 10.232 | De notch-referentie |
| [DamascenoRafael/reminders-menubar](https://github.com/DamascenoRafael/reminders-menubar) | 3.866 | Menubalk-dropdown in SwiftUI |
| [getzep/graphiti](https://github.com/getzep/graphiti) | 29.520 | Als de graph ooit aan de beurt is |
| [eugeniughelbur/obsidian-second-brain](https://github.com/eugeniughelbur/obsidian-second-brain) | 3.816 | Geheugen als platte markdown |
| [RafalWilinski/mcp-apple-notes](https://github.com/RafalWilinski/mcp-apple-notes) | 409 | RAG over Apple Notes |

### Over "Hermes agent"

De repos die daaronder komen bovendrijven (`gbrain`, `hermes-desktop`,
`hermes-workspace`, `hermes-webui`) zijn **agent-frontends** — chat, terminal,
geheugen, skills-inspector. Interessant als inspiratie voor de vorm van een
agent-UI, maar geen bibliotheek die wij kunnen invoegen. `hermes-workspace`
noemt expliciet "memory, skills, inspector" als eersteklas onderdelen; dat is
een aanwijzing dat een zichtbare geheugen- en toolinspector de moeite waard is,
niet dat we hun code nodig hebben.

---

## 9. Risico's

| Risico | Waarschijnlijkheid | Wat het betekent |
|---|---|---|
| **Volledige Schijftoegang schrikt af** | hoog | Notities, berichten en mail hangen er allemaal aan. De onboarding moet uitleggen *waarom*, per bron, niet als één blok. |
| **Privé-databases veranderen van vorm** | midden | Notes en Messages zijn ongedocumenteerd. Elke leesroutine moet falen naar "kon niet lezen", nooit crashen. |
| **De index wordt een tweede kopie van je leven** | midden | Opt-in per bron, lokaal, wisbaar. Zie §4. |
| **qwen3:8b kiest verkeerde tools bij 25+ tools** | hoog | Meer tools maakt selectie moeilijker. Groepeer per domein en overweeg een tool-search-laag. |
| **Menubalk + notch = twee ingangen** | laag | Eén gedeelde SwiftUI-view, geen tweede implementatie. |

Dat vierde risico is het meest onderschat. Meer tools is niet lineair beter: elk
schema kost context en elke extra keuze verhoogt de kans op de verkeerde.

---

## 10. Implementatieplan

Volgorde op waarde, met het goedkope eerst zodat er snel iets te merken is en de
dure keuzes met meer informatie gemaakt worden.

### Fase A — bereik (1–2 dagen)

De tools die vandaag al kunnen, zonder nieuw ontwerp. Dit brengt de toolset van
zestien naar ongeveer zesentwintig — precies het punt waarop fase B nodig wordt.

1. `search_notes`, `read_note` — NoteStore.sqlite, bodies uit de protobuf
2. `create_note` — AppleScript naar Notes (schrijven is snel, lezen niet)
3. `search_messages` — chat.db
4. `list_reminders`, `create_reminder` — EventKit
5. `list_contacts` — Contacts-framework
6. `list_shortcuts`, `run_shortcut` — de oneindige toolset
7. `clipboard_read` / `clipboard_write`
8. `browser_history`

**Klaar wanneer:** "wat weet ik over X" raakt notities én berichten, en je eigen
Shortcuts verschijnen als aanroepbare tools.

### Fase B — orchestrator en specialisten (2–3 dagen)

De architectuur uit §4. Dit is de fase die bepaalt of de app schaalt naar vijftig
tools of vastloopt op dertig.

9.  `Specialist`-type: naam, systeemprompt, tool-deelverzameling, modeltier, max rondes
10. Zes specialisten uit §4.2 — de domeinindeling is de subagent-indeling
11. `delegate_*` tools op de orchestrator; specialisten geven **samenvattingen**
    terug, nooit ruwe uitvoer, met een harde limiet van ~1.500 tekens
12. De drie snelheden uit §4.3: direct / enkelvoudig / gedelegeerd, gestuurd door
    de systeemprompt van de orchestrator — geen apart classificatiemodel
13. Modelrollen instelbaar in instellingen: router, specialist, samenvatter
14. Goedkeuringsvraag door de delegatie heen naar de UI — een specialist die
    `run_shell` aanroept moet dezelfde grendel raken
15. Een zichtbare **trace** in het paneel: welke specialist, welke tools, hoelang

Punt 15 is geen luxe. Zonder trace is een gedelegeerd antwoord een zwarte doos, en
dan is een fout niet te vinden. `hermes-workspace` zet een inspector niet voor
niets naast chat en geheugen.

**Klaar wanneer:** "vat mijn mail samen en zet de deadlines in mijn agenda" raakt
twee specialisten parallel, en "hoeveel batterij" gaat nog steeds in één beurt.

### Fase C — de app als burger van je systeem (1 dag)

16. `NSStatusItem` met dropdown: status, snelle acties, instellingen, afsluiten
17. `Placement`-abstractie: pill-fallback zonder notch
18. Toestemmingen per bron in onboarding, met uitleg per stuk
19. Sneltoets (⌥Space) om het paneel te openen

**Klaar wanneer:** de app draait op een Mac mini en je kunt hem afsluiten zonder
Terminal.

### Fase D — geheugen (3–5 dagen)

20. `NotchAI.sqlite` met FTS5 over notities, mailonderwerpen, gesprekken
21. Achtergrond-indexering, opt-in per bron, met teller en wisknop
22. `search_memory` als tool van de `geheugen`-specialist
23. Embeddings via Ollama `/api/embeddings` + vectorzoeken erbovenop
24. `remember` die feiten naar markdown schrijft, met goedkeuring

**Klaar wanneer:** "wat schreef ik over de kwartaalaangifte" vindt een notitie van
drie maanden terug zonder dat je het juiste woord gebruikt.

### Fase E — pas als D tekortschiet

25. Entiteit-extractie en graph
26. Schermafbeeldingen + vision-model
27. Accessibility-besturing van apps

---

## 11. Wat ik zou doen als het mijn beslissing was

**A en B, en dan pas kijken.** Samen vier tot vijf dagen.

Fase A alleen maakt het erger voordat het beter wordt: zesentwintig tools zonder
routering betekent slechtere toolkeuze dan nu. Dat is de reden dat B er direct
achteraan hoort en niet later — ze zijn samen één verandering, niet twee.

Fase C is een dag en verdubbelt de doelgroep; goedkoop genoeg om er niet lang over
na te denken.

Fase D is de duurste en levert pas op als je de app dagelijks gebruikt. Dat weet je
pas na A, B en C.

Fase E is het meest indrukwekkend om te demonstreren en het snelst verrot. Bewust
achteraan.

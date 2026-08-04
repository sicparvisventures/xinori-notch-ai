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
| Schermafbeeldingen | Vereist Schermopname-toestemming; wél haalbaar, maar een eigen ontwerpvraag (zie §7) |
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

## 4. Het second brain

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

## 5. Aanwezigheid in de menubalk

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

## 6. Zonder notch

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

## 7. Verwante projecten

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

## 8. Risico's

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

## 9. Implementatieplan

Volgorde op waarde, met de goedkope dingen eerst zodat er snel iets te merken is.

### Fase A — bereik (1–2 dagen)

De tools die vandaag al kunnen, zonder nieuw ontwerp.

1. `list_notes`, `read_note`, `search_notes` — NoteStore.sqlite
2. `create_note` — AppleScript naar Notes (schrijven is snel, lezen niet)
3. `search_messages` — chat.db
4. `list_reminders`, `create_reminder` — EventKit
5. `list_contacts` — Contacts-framework
6. `run_shortcut` + `list_shortcuts` — de oneindige toolset
7. `clipboard_read` / `clipboard_write`
8. `browser_history`

**Meetbaar klaar wanneer:** "wat weet ik over X" tenminste notities en berichten
raakt, en `shortcuts list` als tools verschijnt.

### Fase B — de app als burger van je systeem (1 dag)

9. `NSStatusItem` met dropdown: status, snelle acties, instellingen, afsluiten
10. `Placement`-abstractie: pill-fallback zonder notch
11. Toestemmingen per bron in onboarding, met uitleg per stuk

**Meetbaar klaar wanneer:** de app draait op een Mac mini en je kunt hem afsluiten
zonder Terminal.

### Fase C — geheugen, laag 1 en 2 (3–5 dagen)

12. `NotchAI.sqlite` met FTS5 over notities, mailonderwerpen, gesprekken
13. Achtergrond-indexering, opt-in per bron, met teller en wisknop
14. `search_memory` tool
15. Embeddings via Ollama `/api/embeddings` + vectorzoeken erbovenop
16. `remember` tool die feiten naar markdown schrijft, met goedkeuring

**Meetbaar klaar wanneer:** "wat schreef ik over de kwartaalaangifte" een notitie
van drie maanden geleden terugvindt zonder dat je het juiste woord gebruikt.

### Fase D — pas als C tekortschiet

17. Entiteit-extractie en graph
18. Schermafbeeldingen + vision-model
19. Accessibility-besturing van apps

Fase D staat er bewust als "pas als". Het zijn de onderdelen die het meest
indrukwekkend demonstreren en het snelst verrotten.

---

## 10. Wat ik zou doen als het mijn beslissing was

Fase A en B, en dan stoppen om te kijken. Dat is samen drie dagen werk en het
verandert het karakter van de app: van "een chatvenster dat een paar dingen kan
opzoeken" naar "iets dat je Mac kent". Het geheugen uit fase C is duurder en
levert pas iets op als je de app dagelijks gebruikt — en dat weet je pas na A en B.

De graph uit fase D is de meest verleidelijke en de minst verstandige eerste stap.

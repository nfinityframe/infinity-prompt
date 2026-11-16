# Infinity Prompt

Eigen teleprompter voor de Mac. Gebouwd 16 november 2026 als vervanging van de App Store-app Teleprompter, die crashte bij harder en zachter zetten.

## Toetsen (in de prompter)

| Toets | Doet |
|---|---|
| Spatie | Start en stop |
| ↑ / ↓ | Sneller / langzamer |
| Shift vasthouden | Even trager, bij loslaten terug naar het oude tempo |
| ⌥↑ / ⌥↓ | Snelheidssprong |
| → / ← | Volgend / vorig cue-punt |
| Page Down / Up | Pagina verder / terug (pedaal, klikker) |
| Home | Naar het begin |
| M / ⇧M | Spiegelen hier / op tweede scherm |
| ⌘[ / ⌘] | Tekst smaller / breder (of sleep de randen) |
| ⌘E of potlood | Tekst wijzigen in de prompter, Klaar of Esc om terug te gaan |
| ⌘, | Instellingen |
| ⌘2 | Tweede scherm |
| Esc | Terug naar de editor |

Aftellen staat standaard uit, en telt alleen af als je bovenaan begint.

Een regel die begint met `#` is een cue-punt.

## Bediening op afstand

- iPhone: knop met telefoon-icoon onderin, QR-code scannen. Zelfde wifi nodig. Het adres heeft een code, alleen wie die heeft kan bedienen.
- Gamecontroller: A start en stop, L1 vasthouden is even trager, R1 en B springen in snelheid, triggers scrollen. Werkt ook als Zoom vooraan staat.
- Zwevend venster (Instellingen › Venster): de prompter blijft boven Zoom. Toetsen gaan dan naar Zoom, bedien hem met iPhone of controller.
- Pedaal en presentatieklikker werken via de toetsen hierboven.

## Bouwen

`./bouw.sh` zet de app in `Apps/`, in Programma's en in iCloud voor de andere Mac. Daarna een commit en, een push naar github.com/nfinityframe/infinity-prompt (privé). `./bouw.sh proef` bouwt alleen naar `/tmp`.

Updates: de app kijkt bij het starten in iCloud Drive › Infinity Frame › Apps › Infinity Prompt en installeert alleen een ondertekende, nieuwere build. De sleutel staat in `~/Library/Application Support/Infinity Frame/Infinity Prompt/update-sleutel` op de Mac die bouwt. Bouw je ook op de andere Mac, kopieer die sleutel dan mee.

## Testen zonder schermopname

| Opdracht | Doet |
|---|---|
| `-demo -stress` | 4000 willekeurige aanpassingen tijdens het scrollen, eindigt met `stress: ok` |
| `-demo -foto <png>` | Foto van de prompter |
| `-demo -editor -foto <png>` | Foto van de editor |

Testen gebruiken een tijdelijke map, je eigen scripts blijven onaangeroerd.

## Voor wie eraan verder bouwt

- `CONTRACT.md` beschrijft hoe de bestanden samenwerken. `Prompter.shared` in `Model.swift` is de enige bron. Snelheid zet alleen een doel, de scroll volgt zacht. Daardoor kan aanpassen tijdens het lopen niet crashen.
- Geen Swift-macro's (`@State`, `#Preview`): de Command Line Tools hebben de plugin niet.
- Ontwerp naar een referentie van Alex (16-11-2026): zwart, donkere kaarten, grote witte titels, mint alleen als accent.

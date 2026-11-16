# Bouwplan: eigen teleprompter

*16 november 2026 · werknaam: Infinity Prompt*

Eigen Mac-app in Swift, zoals Swipe Opruimer. Vervangt de Teleprompter uit de App Store.

## Het probleem

| Bug | Oorzaak (waarschijnlijk) | Oplossing |
|---|---|---|
| Crasht bij harder/zachter zetten | Scroll en instellingen zitten elkaar in de weg | Eén centrale stand, scroll volgt die soepel |
| Crasht bij andere aanpassingen | Scherm wordt opnieuw opgebouwd tijdens het lopen | Aanpassen zonder herbouw, plek blijft staan |

## Features die we overnemen

| Groep | Feature |
|---|---|
| Scrollen | Start en stop, harder en zachter |
| | Snelheidssprong (bijv. +5 in één keer) |
| | Richting omdraaien, pagina vooruit en terug |
| | Slepen stopt het scrollen |
| Spiegelen | Spiegelen op dit scherm, op het tweede scherm, of allebei |
| Tekst | Lettertype, grootte, marges, regelafstand |
| | Kleur tekst en achtergrond |
| Cue | Cue-lijn met instelbare hoogte |
| | Cue-punten: volgende en vorige |
| Tijd | Aftellen voor de start |
| | Klok met verstreken tijd |
| Tweede scherm | Script schermvullend op monitor of prompter |
| | Los spiegelen van het tweede scherm |
| Bediening | Toetsenbord, voetpedaal, presentatieklikker |
| | Gamecontroller |
| | iPhone via de browser (wifi) |
| Scripts | Lijst met scripts, nieuw, importeren (txt, rtf, docx, pdf) |
| | Opmaak overnemen bij import (ja of nee) |

## Wat we niet overnemen

| Feature | Waarom |
|---|---|
| Video opnemen | Gebruik je niet |
| Automatische ondertitels | Hoort bij opnemen |
| Account en cloud | Niet nodig, scripts staan lokaal |
| Abonnement en betaalschermen | Eigen app |

## Verbeteringen bovenop het origineel

| Verbetering | Wat het doet |
|---|---|
| Resterende tijd | Ziet hoeveel minuten script er nog over is |
| Cue-punt met `#` | Regel met `#` wordt vanzelf een cue-punt |
| Monitor eruit = geen crash | Tweede scherm sluit netjes |

## Bouwen in vier stukken

| Stuk | Wat | Agent |
|---|---|---|
| 1 | Centrale stand en soepel scrollen | Agent A |
| 2 | Scherm: editor, prompter, tweede scherm | Agent B |
| 3 | Bediening: toetsen, controller, iPhone | Agent C |
| 4 | Bouwen, icoon, app in `Apps/` | Ik |

## Test vóór oplevering

Een stresstest die tijdens het scrollen honderden keren snelheid, grootte, spiegelen en het tweede scherm wisselt. Pas als die niet crasht is het af. Daarna een schermafbeelding in de chat.

## Vraag aan Alex

Heb je een referentiebeeld voor het ontwerp?

## Ronde 2 (16 november 2026)

| Wens | Gedaan |
|---|---|
| Aftellen niet altijd | Standaard uit, nooit bij hervatten |
| Shift = even trager | 2 stapjes, instelbaar 1 tot 5, terug bij loslaten |
| Instellingen rustiger | Eigen venster met zes onderdelen |
| Opmaak (Teleprompter Pro) | Vet, cursief, onderstreept, kleur, ook bij Word-import |
| Cue-lijn | Lijn, pijl of beide, kleur, doorzichtigheid |
| Kleur per script | Tekst en achtergrond |
| Zwevend venster | Boven Zoom, doorzichtig |
| Getimed scrollen | Klaar in mm:ss |
| Niet overgenomen | Opnemen, video-effecten, Siri en Snelkoppelingen |

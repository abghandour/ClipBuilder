# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Clip Builder is for video editors and social-media operators who turn a profile’s source footage into short-form clips, often while analysis and rendering continue in the background.

## Product Purpose

The app organizes source footage, analyzed scenes, editable timelines, generated outputs, publishing, and reusable studio resources into one native workflow. Success means an editor can move between distinct jobs without losing context or mixing their media.

## Positioning

Clip Builder combines AI-assisted scene understanding and reel planning with a fully editable, multi-track timeline and performance feedback from published Instagram content.

## Operating Context

Work is stored under brand profiles. Each profile owns its folders, database, people identities, Instagram account, and reusable resources. Within a profile, projects separate jobs while background analysis and rendering may continue across project switches.

## Capabilities and Constraints

- Projects are per profile. A source video may belong to more than one project.
- Unassigned files discovered in the Input folder remain in an Inbox until assigned.
- Projects contain source membership, scoped scenes, multiple Builder timelines, Wizard runs, and generated outputs.
- People and resources remain profile-wide; project views may prioritize relevant people without changing identity ownership.
- Deleting a project asks whether generated files should also be removed and defaults to keeping files.
- The existing native macOS editing, analysis, curation, critique, publishing, and profile workflows must remain available.
- Inferred from the supplied project proposal: no additional per-project Wizard settings are required beyond the listed UI state.

## Brand Commitments

The product name remains Clip Builder. The interface uses native macOS controls and the supplied project-centered mockups are binding visual references for this redesign.

## Evidence on Hand

- Product proposal and behavior specification: `docs/ui-projects/README.md`.
- Approved rendered references: `docs/ui-projects/Home.png`, `Main.png`, `Timelines.png`, and `Builder.png`.
- Editable mockup sources: `docs/ui-projects/mockup-source/`.
- Existing production workflows and real data are present in the SwiftUI app; no testimonials or commercial claims were supplied and none should be fabricated.

## Product Principles

- Keep every job’s working context intact.
- Make project scope obvious at every editing step.
- Preserve profile-wide knowledge and assets across projects.
- Keep long-running work visible without blocking navigation.
- Prefer direct, native controls over hidden modes.

## Accessibility & Inclusion

Preserve native macOS keyboard navigation, VoiceOver labels, system colors, text scaling, reduced-motion behavior, and non-color status cues.

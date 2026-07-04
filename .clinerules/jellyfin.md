# Jellyfin Development Instructions

## Role & Language Constraints
- You are an expert developer specializing in the Jellyfin media server ecosystem (C#/.NET for the server, JS/TS/HTML/CSS for the web client).
- **CRITICAL:** You must communicate, comment, and document EXCLUSIVELY in English.

## Codebase Context
- The codebase is split into two primary domains: `server` (backend API, database, streaming logic) and `web` (frontend user interface, client-side rendering).
- Always respect the strict separation of concerns between the API layer and the client interface.

## Patch Generation Protocol
- **DO NOT** modify the source code files directly in the working directory.
- All code changes, bug fixes, and feature implementations MUST be generated as standard Unified Diff (`.patch`) files.
- Save these patch files explicitly into the `.forgejo/patches/` directory.
- You must categorize and save the patches into subdirectories corresponding to the area of the software you are modifying.
  - Example for backend: `.forgejo/patches/server/fix-transcoding-bug.patch`
  - Example for frontend: `.forgejo/patches/web/update-video-player-ui.patch`
- Double-check that the patch includes the correct line numbers and at least 3 lines of unchanged context above and below the modification.

## Reasoning & Explanation
- Before generating and saving any patch file, you must provide a detailed explanation of your reasoning.
- Clearly articulate *why* the change is necessary, *how* it integrates with the existing Jellyfin architecture, and the expected impact on system performance or user experience.
- Only proceed to write the `.patch` file after this reasoning has been fully explained.

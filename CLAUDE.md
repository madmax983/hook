# Hook - Webhooks for Salesforce

Hook gives inbound and outbound webhooks to Apex. An optional adapter runs them as durable Revenant workflows.

## Layout

- `force-app`: the core. No Revenant reference.
- `revenant-adapter`: `HookRevenantChannel`, `HookRevenantDelivery`, `HookRevenantInboundHandler`. Uses only global APIs.
- `lib/revenant`: Revenant as a submodule, for the compile check and the org tests.
- `docs/plans`: the design and the acceptance criteria. `docs/adr`: decisions. `docs/api.md`: the global API manifest.

## Commands

- **Node tests (vectors, API manifest, coverage script)**: `npm test`
- **Compile all Apex with no org**: `npm run check:apex-compile` (run `bash scripts/apex-ls/fetch-apex-ls.sh` one time, and `git submodule update --init --recursive`)
- **Format Apex**: `npm run format`. **Check**: `npm run format:check`
- **Code Analyzer (as CI does)**: `sf code-analyzer run --workspace force-app --workspace revenant-adapter --rule-selector recommended --severity-threshold 2`
- **Rebuild the signature vectors**: `npm run vectors`
- **Deploy and test in an org**: `sf project deploy start`, then `sf apex run test --class-names <Hook...Test> --code-coverage --wait 30`

## Rules

- Write the test first. Then the code. Then refactor.
- A change to a `global` declaration must change `docs/api.md` in the same commit.
- Engine internals that must see every row are `without sharing`, and say why in the class comment. Use `WITH SYSTEM_MODE` and `as system` on their SOQL and DML.
- No callout after DML in one transaction. A channel only claims. `HookDispatchJob` sends, then writes.
- Comments and docs use ASD-STE100: short sentences, active voice, one idea in each sentence.

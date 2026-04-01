# Style & Conventions

- Follow EvmKit.Swift patterns (Kit facade, separate Signer, Storage classes)
- `struct` for data models with `Codable`
- `enum SyncState` with associated values (not sealed class)
- Combine publishers for reactive API (`CurrentValueSubject`, `PassthroughSubject`)
- `async throws` for async operations
- GRDB: `FetchableRecord` / `PersistableRecord` for persistence
- Minimal comments — only where logic isn't self-evident

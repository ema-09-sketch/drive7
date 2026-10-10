# MyDrive iOS

App iPhone minimale che apre direttamente:

`http://100.69.14.53`

## Cosa contiene

- WKWebView con URL fisso, senza schermata impostazioni.
- Compatibilità HTTP/VPN tramite App Transport Security (`NSAllowsArbitraryLoads`).
- Messaggio semplice + pulsante **Riprova** se il server/VPN non è raggiungibile.
- Cookie/sessioni persistenti tramite `WKWebsiteDataStore.default()`.
- Nessun player audio nativo, Media Session, background audio, widget, EQ o cache musicale.
- Bundle ID distinto (`com.example.MyDrive`), quindi può convivere con MyMusic.

## Build da Windows

1. Carica **il contenuto di questa cartella** nella root di un repository GitHub.
2. Collega il repository a Codemagic.
3. Avvia il workflow **MyDrive iOS - Unsigned IPA**.
4. Scarica `MyDrive-unsigned.ipa` dagli Artifacts.
5. Apri Sideloadly su Windows, trascina l'IPA e installala sul tuo iPhone.

Con un Apple ID gratuito valgono le normali limitazioni della firma development di Sideloadly.

## Download su iPhone

I download MyDrive vengono gestiti nativamente dall'app:

- il frontend passa URL e nome file a Swift tramite `WKScriptMessageHandler`;
- Swift scarica il file reale con `URLSession`, mantenendo i cookie della sessione MyDrive;
- al termine viene aperto `UIDocumentPickerViewController` con un file locale reale;
- il file viene copiato nella posizione scelta in File e la copia temporanea viene eliminata solo dopo la chiusura del picker;
- resta anche un fallback `WKDownload` per le risposte HTTP con `Content-Disposition: attachment`.

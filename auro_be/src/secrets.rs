//! Secrets at rest: settings and tokens the database holds encrypted
//! (the `settings` table's secret values, the Questrade tokens).
//!
//! AES-256-GCM with a random 12-byte nonce, the value's name as associated
//! data (so a value copied under another name won't decrypt), written as
//! text: `enc:v1:` then hex of nonce ‖ ciphertext ‖ tag. Opus writes the
//! same format with Erlang's `:crypto` (`Opus.Settings.Secret`); the test
//! below decrypts a value Opus made.
//!
//! The key is `AURO_SECRETS_KEY`, 64 hex characters (32 bytes,
//! `openssl rand -hex 32`), set in both apps' `.env`. It never goes into the
//! database, so a backup holds the values but can't read them.

use std::sync::OnceLock;

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};

const PREFIX: &str = "enc:v1:";
const NONCE_LEN: usize = 12;

/// The key that opens the stored secrets.
#[derive(Clone)]
pub struct SecretsKey(Aes256Gcm);

impl std::fmt::Debug for SecretsKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretsKey(..)")
    }
}

impl SecretsKey {
    /// From `AURO_SECRETS_KEY`'s 64 hex characters.
    pub fn from_hex(hex: &str) -> Result<Self, String> {
        let bytes = decode_hex(hex.trim())
            .filter(|b| b.len() == 32)
            .ok_or("AURO_SECRETS_KEY must be 64 hex characters (openssl rand -hex 32)")?;
        Aes256Gcm::new_from_slice(&bytes)
            .map(Self)
            .map_err(|_| "AURO_SECRETS_KEY is not a valid key".to_string())
    }

    /// `plain` encrypted under `name`.
    pub fn encrypt(&self, name: &str, plain: &str) -> String {
        let mut nonce = [0u8; NONCE_LEN];
        rand::fill(&mut nonce);
        self.encrypt_with(name, plain, nonce)
    }

    fn encrypt_with(&self, name: &str, plain: &str, nonce: [u8; NONCE_LEN]) -> String {
        let sealed = self
            .0
            .encrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: plain.as_bytes(),
                    aad: name.as_bytes(),
                },
            )
            .expect("AES-GCM encryption of a short value can't fail");
        let mut out = String::from(PREFIX);
        for byte in nonce.iter().chain(&sealed) {
            out.push_str(&format!("{byte:02x}"));
        }
        out
    }

    /// The plain value of `stored` under `name`. A value without the
    /// prefix is plain text (written before encryption existed) and comes
    /// back as is. An error when it's encrypted but won't open: a different
    /// key, a damaged value, or the wrong name.
    pub fn decrypt(&self, name: &str, stored: &str) -> Result<String, String> {
        let Some(hex) = stored.strip_prefix(PREFIX) else {
            return Ok(stored.to_string());
        };
        let bytes = decode_hex(hex).ok_or_else(|| format!("{name}: not valid hex"))?;
        if bytes.len() < NONCE_LEN + 16 {
            return Err(format!("{name}: too short to be encrypted"));
        }
        let (nonce, sealed) = bytes.split_at(NONCE_LEN);
        let nonce: [u8; NONCE_LEN] = nonce.try_into().expect("split at the nonce length");
        let plain = self
            .0
            .decrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: sealed,
                    aad: name.as_bytes(),
                },
            )
            .map_err(|_| format!("{name}: won't decrypt with AURO_SECRETS_KEY (another key?)"))?;
        String::from_utf8(plain).map_err(|_| format!("{name}: not text"))
    }
}

/// The process's key, installed once at start-up (`install`), for code
/// that stores a secret mid-run (the Questrade tokens as they rotate).
static KEY: OnceLock<SecretsKey> = OnceLock::new();

/// Install the key `seal` and `open` use. The live engine refuses to start
/// without one (`Config`); the tester holds no secrets of its own.
pub fn install(key: SecretsKey) {
    let _ = KEY.set(key);
}

/// `plain` sealed under `name` with the installed key. With none installed
/// (only a process that never stores secrets) it stays plain.
pub fn seal(name: &str, plain: &str) -> String {
    match KEY.get() {
        Some(key) => key.encrypt(name, plain),
        None => plain.to_string(),
    }
}

/// The plain value of `stored` under `name` (`SecretsKey::decrypt`); an
/// error when it's encrypted and no key is installed.
pub fn open(name: &str, stored: &str) -> Result<String, String> {
    match KEY.get() {
        Some(key) => key.decrypt(name, stored),
        None if !is_encrypted(stored) => Ok(stored.to_string()),
        None => Err(format!(
            "{name} is encrypted and AURO_SECRETS_KEY isn't set"
        )),
    }
}

/// Whether `stored` is an encrypted value.
pub fn is_encrypted(stored: &str) -> bool {
    stored.starts_with(PREFIX)
}

fn decode_hex(hex: &str) -> Option<Vec<u8>> {
    if !hex.len().is_multiple_of(2) {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bytes 0..31 as hex: a known key Opus's test shares, not a secret.
    fn key_hex() -> String {
        (0u8..32).map(|b| format!("{b:02x}")).collect()
    }
    /// Made by Opus (Erlang `:crypto`) with `key_hex()`, nonce a0a1…ab, name
    /// OANDA_API_KEY: "s3cret-value".
    const FROM_OPUS: &str =
        "enc:v1:a0a1a2a3a4a5a6a7a8a9aaab952b1f5f20bf2fc90309f2b6577871c427e4848c944673a3675347bf";

    #[test]
    fn opens_what_opus_sealed_and_seals_it_the_same_way() {
        let key = SecretsKey::from_hex(&key_hex()).unwrap();
        assert_eq!(
            key.decrypt("OANDA_API_KEY", FROM_OPUS).unwrap(),
            "s3cret-value"
        );
        let nonce: [u8; 12] = decode_hex("a0a1a2a3a4a5a6a7a8a9aaab")
            .unwrap()
            .try_into()
            .unwrap();
        assert_eq!(
            key.encrypt_with("OANDA_API_KEY", "s3cret-value", nonce),
            FROM_OPUS
        );
    }

    #[test]
    fn a_value_wont_open_under_another_name_or_key() {
        let key = SecretsKey::from_hex(&key_hex()).unwrap();
        assert!(key.decrypt("MASSIVE_API_KEY", FROM_OPUS).is_err());
        let other = SecretsKey::from_hex(&"11".repeat(32)).unwrap();
        assert!(other.decrypt("OANDA_API_KEY", FROM_OPUS).is_err());
    }

    #[test]
    fn round_trips_with_a_fresh_nonce_each_time_and_passes_plain_text_through() {
        let key = SecretsKey::from_hex(&key_hex()).unwrap();
        let a = key.encrypt("questrade.refresh_token", "tok");
        let b = key.encrypt("questrade.refresh_token", "tok");
        assert_ne!(a, b);
        assert!(is_encrypted(&a));
        assert_eq!(key.decrypt("questrade.refresh_token", &a).unwrap(), "tok");
        assert_eq!(
            key.decrypt("questrade.refresh_token", "plain").unwrap(),
            "plain"
        );
    }

    #[test]
    fn a_bad_key_is_refused() {
        assert!(SecretsKey::from_hex("abc").is_err());
        assert!(SecretsKey::from_hex(&"zz".repeat(32)).is_err());
    }
}

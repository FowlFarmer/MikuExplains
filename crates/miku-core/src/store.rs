//! SQLite capture/result store. Replaces the Swift file-based `CaptureStore`
//! (one `.md` per capture + one `-result.json` per summary) with a single
//! bundled-SQLite database so the packaged app ships without a DB server and
//! without scattering files in Application Support.

use chrono::{DateTime, Local, TimeZone};
use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;

use crate::models::{ParsedSummary, ResultCard};

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("summary not found: {0}")]
    NotFound(i64),
}

/// A persisted capture (the highlighted source text).
#[derive(Debug, Clone)]
pub struct CaptureRecord {
    pub id: i64,
    pub base_name: String,
    pub captured_at: i64,
}

/// A persisted result, shaped for the React UI (`id`, `displayTimestamp`, ...).
#[derive(Debug, Clone, Serialize)]
pub struct SummaryRecord {
    pub id: String,
    #[serde(rename = "displayTimestamp")]
    pub display_timestamp: String,
    pub tagline: String,
    #[serde(rename = "primary_intent")]
    pub primary_intent: String,
    #[serde(rename = "intent_confidence")]
    pub intent_confidence: String,
    #[serde(rename = "used_web_search")]
    pub used_web_search: bool,
    pub items: Vec<ResultCard>,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    /// Open (creating if needed) the database at `path` and run migrations.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self, StoreError> {
        let conn = Connection::open(path)?;
        Self::from_connection(conn)
    }

    /// In-memory store, used by tests.
    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(conn: Connection) -> Result<Self, StoreError> {
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS captures (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                base_name   TEXT NOT NULL,
                text        TEXT NOT NULL,
                captured_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS summaries (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                capture_id        INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                tagline           TEXT NOT NULL,
                primary_intent    TEXT NOT NULL,
                intent_confidence TEXT NOT NULL,
                used_web_search   INTEGER NOT NULL,
                cards_json        TEXT NOT NULL,
                created_at        INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_summaries_created ON summaries(created_at DESC);
            "#,
        )?;
        Ok(Self { conn })
    }

    /// Persist captured text. Returns the new capture row.
    pub fn save_capture(&self, text: &str) -> Result<CaptureRecord, StoreError> {
        let now = Local::now();
        let base_name = now.format("%Y-%m-%d_%H-%M-%S").to_string();
        let captured_at = now.timestamp();

        self.conn.execute(
            "INSERT INTO captures (base_name, text, captured_at) VALUES (?1, ?2, ?3)",
            rusqlite::params![base_name, text, captured_at],
        )?;
        let id = self.conn.last_insert_rowid();
        Ok(CaptureRecord { id, base_name, captured_at })
    }

    /// Persist a parsed summary for a capture and return the UI-shaped record.
    pub fn save_summary(
        &self,
        summary: &ParsedSummary,
        capture: &CaptureRecord,
    ) -> Result<SummaryRecord, StoreError> {
        let cards_json = serde_json::to_string(&summary.cards)?;
        let created_at = Local::now().timestamp();

        self.conn.execute(
            "INSERT INTO summaries
                (capture_id, tagline, primary_intent, intent_confidence, used_web_search, cards_json, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                capture.id,
                summary.tagline,
                summary.primary_intent,
                summary.intent_confidence,
                summary.used_web_search as i64,
                cards_json,
                created_at,
            ],
        )?;
        let id = self.conn.last_insert_rowid();

        Ok(SummaryRecord {
            id: id.to_string(),
            display_timestamp: display_timestamp(created_at),
            tagline: summary.tagline.clone(),
            primary_intent: summary.primary_intent.clone(),
            intent_confidence: summary.intent_confidence.clone(),
            used_web_search: summary.used_web_search,
            items: summary.cards.clone(),
        })
    }

    /// List summaries newest-first. Cards are loaded too (cheap; bodies are small).
    pub fn list_summaries(&self) -> Result<Vec<SummaryRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, tagline, primary_intent, intent_confidence, used_web_search, cards_json, created_at
             FROM summaries ORDER BY created_at DESC, id DESC",
        )?;
        let rows = stmt.query_map([], Self::row_to_record)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Load a single summary by its string id.
    pub fn load_summary(&self, id: &str) -> Result<SummaryRecord, StoreError> {
        let parsed_id: i64 = id.parse().map_err(|_| StoreError::NotFound(-1))?;
        let record = self
            .conn
            .query_row(
                "SELECT id, tagline, primary_intent, intent_confidence, used_web_search, cards_json, created_at
                 FROM summaries WHERE id = ?1",
                [parsed_id],
                Self::row_to_record,
            )
            .optional()?;
        record.ok_or(StoreError::NotFound(parsed_id))
    }

    fn row_to_record(row: &rusqlite::Row) -> rusqlite::Result<SummaryRecord> {
        let id: i64 = row.get(0)?;
        let cards_json: String = row.get(5)?;
        let created_at: i64 = row.get(6)?;
        let items: Vec<ResultCard> = serde_json::from_str(&cards_json).unwrap_or_default();
        Ok(SummaryRecord {
            id: id.to_string(),
            display_timestamp: display_timestamp(created_at),
            tagline: row.get(1)?,
            primary_intent: row.get(2)?,
            intent_confidence: row.get(3)?,
            used_web_search: row.get::<_, i64>(4)? != 0,
            items,
        })
    }
}

/// "MMM d, h:mm a" — matches the Swift display format (e.g. "May 19, 2:14 AM").
fn display_timestamp(epoch_secs: i64) -> String {
    match Local.timestamp_opt(epoch_secs, 0).single() {
        Some(dt) => format_display(dt),
        None => epoch_secs.to_string(),
    }
}

fn format_display(dt: DateTime<Local>) -> String {
    // %-d / %-I are GNU extensions; build the no-leading-zero form manually for
    // portability across platforms (macOS strftime lacks %-d).
    let day = dt.format("%d").to_string();
    let day = day.trim_start_matches('0');
    let hour24 = dt.format("%H").to_string().parse::<u32>().unwrap_or(0);
    let (hour12, ampm) = match hour24 {
        0 => (12, "AM"),
        1..=11 => (hour24, "AM"),
        12 => (12, "PM"),
        _ => (hour24 - 12, "PM"),
    };
    let month = dt.format("%b").to_string();
    let minute = dt.format("%M").to_string();
    format!("{month} {day}, {hour12}:{minute} {ampm}")
}

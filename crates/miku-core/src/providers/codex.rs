//! Local Codex CLI provider. Port of the Swift `CodexSummarizer.runCodex`.
//!
//! Spawns `codex exec --sandbox read-only --output-last-message <tmp> <prompt>`
//! and reads the last-message file. `--search` is prepended for the web pass.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

use super::{Provider, ProviderError};

pub struct CodexProvider {
    executable: PathBuf,
}

impl CodexProvider {
    /// Locate the codex binary using the same candidate paths as the Swift app.
    pub fn locate() -> Result<Self, ProviderError> {
        const CANDIDATES: &[&str] = &[
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/bin/codex",
        ];
        for c in CANDIDATES {
            let p = PathBuf::from(c);
            if is_executable(&p) {
                return Ok(Self { executable: p });
            }
        }
        // Fall back to PATH lookup.
        if let Ok(path) = which("codex") {
            return Ok(Self { executable: path });
        }
        Err(ProviderError::ExecutableNotFound("codex".into()))
    }

    pub fn with_executable(executable: impl Into<PathBuf>) -> Self {
        Self { executable: executable.into() }
    }
}

impl Provider for CodexProvider {
    fn name(&self) -> &str {
        "codex"
    }

    fn supports_web_search(&self) -> bool {
        true
    }

    fn complete(&self, prompt: &str, web_search: bool) -> Result<String, ProviderError> {
        let tmp = std::env::temp_dir().join(format!(
            "miku-codex-{}.txt",
            std::process::id()
        ));

        let mut args: Vec<String> = Vec::new();
        if web_search {
            args.push("--search".into());
        }
        args.push("exec".into());
        args.push("--skip-git-repo-check".into());
        args.push("--sandbox".into());
        args.push("read-only".into());
        args.push("--output-last-message".into());
        args.push(tmp.to_string_lossy().into_owned());
        args.push(prompt.to_string());

        let output = Command::new(&self.executable)
            .args(&args)
            .output()
            .map_err(|e| ProviderError::LaunchFailed(e.to_string()))?;

        if !output.status.success() {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return Err(ProviderError::Failed {
                status: output.status.code().unwrap_or(-1),
                output: combined,
            });
        }

        let text = fs::read_to_string(&tmp)
            .map_err(|e| ProviderError::UnreadableOutput(e.to_string()))?;
        let _ = fs::remove_file(&tmp);
        Ok(text)
    }
}

fn is_executable(path: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn which(bin: &str) -> Result<PathBuf, ProviderError> {
    let path = std::env::var_os("PATH")
        .ok_or_else(|| ProviderError::ExecutableNotFound(bin.into()))?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(bin);
        if is_executable(&candidate) {
            return Ok(candidate);
        }
    }
    Err(ProviderError::ExecutableNotFound(bin.into()))
}

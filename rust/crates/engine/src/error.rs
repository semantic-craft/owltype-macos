//! The crate's one error type. Display strings are part of the contract: hosts surface them, and the host tests and goldens compare the exact C++ wording, so constructors take the message from `diagnostics` rather than composing new text.

pub type Result<T, E = EngineError> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    /// A caller-supplied value was rejected (the C++ `std::invalid_argument`).
    #[error("{0}")]
    InvalidArgument(String),
    /// An operation could not complete (the C++ `std::runtime_error`).
    #[error("{0}")]
    Failed(String),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl EngineError {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidArgument(message.into())
    }

    pub fn failed(message: impl Into<String>) -> Self {
        Self::Failed(message.into())
    }
}

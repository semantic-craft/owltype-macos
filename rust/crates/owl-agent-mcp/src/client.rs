//! The helper's side of the bridge: one connection per tool call, opened only to a socket the
//! current user owns in a directory only they can open, answered by a process of the same user.
//! Owltype.app checks the other direction (same user, then the helper's code signature).

use crate::bridge::{
    Call, Component, ErrorCode, HelloParams, Method, Outcome, Request, RequestId, Response, MAX_LINE_BYTES,
    PROTOCOL_VERSION,
};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// Overrides the socket location; tests and development builds use it.
pub const SOCKET_ENV: &str = "OWLTYPE_AGENT_BRIDGE_SOCKET";
/// Time for connect, `hello` and any read-only call.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// Slack on top of a `deliver_text` confirmation window for the App to answer.
pub const DELIVER_GRACE: Duration = Duration::from_secs(5);
/// macOS `sun_path` holds 104 bytes including the terminator.
const MAX_SOCKET_PATH: usize = 103;

/// `~/Library/Application Support/Owltype/AgentBridge/bridge.sock`, the path OwlAgentBridge binds.
pub fn socket_path() -> Result<PathBuf, BridgeError> {
    if let Some(path) = std::env::var_os(SOCKET_ENV) {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").ok_or(BridgeError::NoHome)?;
    Ok(PathBuf::from(home).join("Library/Application Support/Owltype/AgentBridge/bridge.sock"))
}

#[derive(Debug, PartialEq)]
pub enum BridgeError {
    NoHome,
    /// No socket, or nothing listening: Owltype is not running or Agent access is off.
    Offline,
    /// The socket or its directory is not private to this user.
    Untrusted(String),
    Timeout,
    Io(String),
    Protocol(String),
    /// The App answered with a bridge error.
    Remote { code: ErrorCode, message: String },
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BridgeError::NoHome => write!(f, "HOME is not set, so the Owltype bridge socket cannot be located"),
            BridgeError::Offline => write!(
                f,
                "Owltype is not reachable: it is not running, or Agent access is turned off in Owltype settings (Agent 接入)"
            ),
            BridgeError::Untrusted(why) => write!(f, "refusing the Owltype bridge socket: {why}"),
            BridgeError::Timeout => write!(f, "Owltype did not answer in time"),
            BridgeError::Io(why) => write!(f, "Owltype bridge connection failed: {why}"),
            BridgeError::Protocol(why) => write!(f, "Owltype bridge protocol error: {why}"),
            BridgeError::Remote { code, message } => write!(f, "Owltype refused the request ({}): {message}", code.name()),
        }
    }
}

impl std::error::Error for BridgeError {}

fn verify_private(path: &Path) -> Result<(), BridgeError> {
    if path.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(BridgeError::Untrusted(format!("socket path is longer than {MAX_SOCKET_PATH} bytes")));
    }
    let uid = rustix::process::getuid().as_raw();
    let socket = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(BridgeError::Offline),
        Err(error) => return Err(BridgeError::Io(error.to_string())),
    };
    if !std::os::unix::fs::FileTypeExt::is_socket(&socket.file_type()) {
        return Err(BridgeError::Untrusted("the path is not a socket".into()));
    }
    if socket.uid() != uid {
        return Err(BridgeError::Untrusted("the socket belongs to another user".into()));
    }
    let directory = path.parent().ok_or_else(|| BridgeError::Untrusted("the socket has no directory".into()))?;
    let directory = std::fs::symlink_metadata(directory).map_err(|error| BridgeError::Io(error.to_string()))?;
    if !directory.is_dir() || directory.uid() != uid || directory.permissions().mode() & 0o077 != 0 {
        return Err(BridgeError::Untrusted("the socket directory is not private (0700, owned by this user)".into()));
    }
    Ok(())
}

/// A connection that has completed `hello`.
pub struct BridgeConnection {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    next_id: u64,
    pub app_protocol_version: u32,
}

impl BridgeConnection {
    pub async fn open(path: &Path, agent_client: Option<Component>) -> Result<BridgeConnection, BridgeError> {
        verify_private(path)?;
        let stream = match tokio::time::timeout(CALL_TIMEOUT, UnixStream::connect(path)).await {
            Err(_) => return Err(BridgeError::Timeout),
            Ok(Err(error)) if matches!(error.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound) => {
                return Err(BridgeError::Offline)
            }
            Ok(Err(error)) => return Err(BridgeError::Io(error.to_string())),
            Ok(Ok(stream)) => stream,
        };
        let peer = stream.peer_cred().map_err(|error| BridgeError::Io(error.to_string()))?;
        if peer.uid() != rustix::process::getuid().as_raw() {
            return Err(BridgeError::Untrusted("the listening process belongs to another user".into()));
        }
        let (reader, writer) = stream.into_split();
        let mut connection = BridgeConnection { reader: BufReader::new(reader), writer, next_id: 1, app_protocol_version: 0 };
        let hello = Call::Hello(HelloParams {
            protocol_version: PROTOCOL_VERSION,
            helper: Component { name: "owltype-mcp".into(), version: env!("CARGO_PKG_VERSION").into() },
            agent_client,
        });
        match connection.call(&hello, CALL_TIMEOUT).await? {
            Outcome::Hello(result) if result.protocol_version == PROTOCOL_VERSION => {
                connection.app_protocol_version = result.protocol_version;
                Ok(connection)
            }
            Outcome::Hello(result) => {
                Err(BridgeError::Protocol(format!("Owltype speaks bridge protocol {}", result.protocol_version)))
            }
            _ => Err(BridgeError::Protocol("hello answered with another result".into())),
        }
    }

    pub async fn call(&mut self, call: &Call, timeout: Duration) -> Result<Outcome, BridgeError> {
        let id = self.next_id;
        self.next_id += 1;
        let mut line = serde_json::to_vec(&Request::new(RequestId::Number(id), call)).expect("requests always serialize");
        line.push(b'\n');
        let exchange = async {
            self.writer.write_all(&line).await.map_err(|error| BridgeError::Io(error.to_string()))?;
            read_line(&mut self.reader).await
        };
        let answer = tokio::time::timeout(timeout, exchange).await.map_err(|_| BridgeError::Timeout)??;
        decode_answer(call.method(), id, &answer)
    }
}

async fn read_line(reader: &mut (impl AsyncBufRead + Unpin)) -> Result<Vec<u8>, BridgeError> {
    let mut line = Vec::new();
    loop {
        let buffer = reader.fill_buf().await.map_err(|error| BridgeError::Io(error.to_string()))?;
        if buffer.is_empty() {
            return Err(BridgeError::Io("Owltype closed the connection".into()));
        }
        let end = buffer.iter().position(|&byte| byte == b'\n');
        let taken = end.unwrap_or(buffer.len());
        line.extend_from_slice(&buffer[..taken]);
        reader.consume(taken + usize::from(end.is_some()));
        if line.len() > MAX_LINE_BYTES {
            return Err(BridgeError::Protocol("answer longer than 1 MiB".into()));
        }
        if end.is_some() {
            return Ok(line);
        }
    }
}

fn decode_answer(method: Method, id: u64, line: &[u8]) -> Result<Outcome, BridgeError> {
    let response: Response = serde_json::from_slice(line).map_err(|error| BridgeError::Protocol(error.to_string()))?;
    match response {
        Response::Success(success) if success.id == RequestId::Number(id) => {
            Outcome::decode(method, success.result).map_err(|error| BridgeError::Protocol(error.to_string()))
        }
        Response::Failure(failure) if failure.id.is_none() || failure.id == Some(RequestId::Number(id)) => {
            Err(BridgeError::Remote { code: failure.error.code, message: failure.error.message })
        }
        _ => Err(BridgeError::Protocol("answer for another request".into())),
    }
}

/// Opens a connection, makes one call and closes it.
pub async fn call_once(call: &Call, agent_client: Option<Component>, timeout: Duration) -> Result<Outcome, BridgeError> {
    let path = socket_path()?;
    let mut connection = BridgeConnection::open(&path, agent_client).await?;
    connection.call(call, timeout).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use tokio::io::AsyncReadExt;

    async fn buffered_answer(bytes: &[u8]) -> BufReader<tokio::net::unix::OwnedReadHalf> {
        let (mut sender, receiver) = UnixStream::pair().unwrap();
        sender.write_all(bytes).await.unwrap();
        sender.shutdown().await.unwrap();
        let (receiver, _) = receiver.into_split();
        let mut reader = BufReader::with_capacity(bytes.len(), receiver);
        assert_eq!(reader.fill_buf().await.unwrap(), bytes);
        reader
    }

    #[tokio::test]
    async fn rejects_oversized_answer_when_newline_arrives_with_final_byte() {
        let tail = buffered_answer(b"a\n").await;
        let mut reader = Cursor::new(vec![b'a'; MAX_LINE_BYTES]).chain(tail);
        let result = read_line(&mut reader).await;
        assert!(
            matches!(result, Err(BridgeError::Protocol(_))),
            "expected Protocol, received an answer with {:?} bytes",
            result.as_ref().map(Vec::len)
        );
    }

    #[tokio::test]
    async fn accepts_maximum_sized_answer_with_newline() {
        let tail = buffered_answer(b"\n").await;
        let mut reader = Cursor::new(vec![b'a'; MAX_LINE_BYTES]).chain(tail);
        assert_eq!(read_line(&mut reader).await.unwrap(), vec![b'a'; MAX_LINE_BYTES]);
    }

    #[tokio::test]
    async fn rejects_oversized_unterminated_answer() {
        let tail = buffered_answer(b"a").await;
        let mut reader = Cursor::new(vec![b'a'; MAX_LINE_BYTES]).chain(tail);
        assert!(matches!(read_line(&mut reader).await, Err(BridgeError::Protocol(_))));
    }

    #[tokio::test]
    async fn preserves_utf8_and_following_lines_and_reports_eof() {
        let mut reader = buffered_answer("猫头鹰\nnext\npartial".as_bytes()).await;
        assert_eq!(read_line(&mut reader).await.unwrap(), "猫头鹰".as_bytes());
        assert_eq!(read_line(&mut reader).await.unwrap(), b"next");
        assert!(matches!(read_line(&mut reader).await, Err(BridgeError::Io(_))));
        assert!(matches!(read_line(&mut reader).await, Err(BridgeError::Io(_))));
    }
}


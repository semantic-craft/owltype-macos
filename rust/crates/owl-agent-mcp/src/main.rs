//! `owltype-mcp`: the stdio MCP server an agent client launches. It holds no input state; every
//! tool call goes to Owltype.app over the bridge socket.

use owl_agent_mcp::server::OwltypeMcp;
use rmcp::ServiceExt;

fn main() -> std::process::ExitCode {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
        None => {}
        Some("--version") => {
            println!("owltype-mcp {} (bridge protocol {})", env!("CARGO_PKG_VERSION"), owl_agent_mcp::bridge::PROTOCOL_VERSION);
            return std::process::ExitCode::SUCCESS;
        }
        Some(other) => {
            eprintln!("usage: owltype-mcp [--version]  (unknown argument {other:?}); it speaks MCP on stdin/stdout");
            return std::process::ExitCode::from(64);
        }
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime");
    let served = runtime.block_on(async {
        let service = OwltypeMcp.serve(rmcp::transport::stdio()).await?;
        service.waiting().await?;
        Ok::<(), Box<dyn std::error::Error>>(())
    });
    match served {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("owltype-mcp: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

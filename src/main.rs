use std::{
    convert::Infallible,
    time::{Duration, Instant},
};

use bytes::Bytes;
use clap::Parser;
use futures::future::Either;
use hdrhistogram::Histogram;
use http::{Method, Request, Response, StatusCode};
use http_body_util::Full;
use hyper::{body::Body, client};
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server,
};
use rand::prelude::*;
use tokio::{
    net::{TcpListener, TcpStream},
    select,
};

#[derive(Debug, clap::Parser)]
struct Args {
    #[clap(subcommand)]
    mode: Mode,
}

#[derive(Debug, Clone, clap::Parser)]
enum Mode {
    Client {
        #[clap(short, long, default_value = "127.0.0.1:8080")]
        addr: String,
        #[clap(short, long, default_value = "/")]
        uri: String,
        #[clap(short, long, default_value_t = 1024)]
        payload_size: usize,
        #[clap(value_parser = humantime::parse_duration, short, long)]
        time: Option<Duration>,
        #[clap(short, long, default_value_t = 1024)]
        rps: usize,
    },
    Server {
        #[clap(short, long, default_value = "127.0.0.1:8080")]
        addr: String,
        #[clap(short, long, default_value_t = 1024)]
        payload_size: usize,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args = Args::parse();
    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);
    match args.mode {
        Mode::Client {
            addr,
            uri,
            payload_size,
            time,
            rps,
        } => {
            let mut hist = Histogram::<u64>::new(5).unwrap();
            let mut body = vec![0; payload_size];
            thread_rng().fill_bytes(&mut body);
            let tcp_conn = TcpStream::connect(addr).await?;
            let (mut send_req, conn) = client::conn::http2::Builder::new(TokioExecutor::new())
                .max_concurrent_reset_streams(usize::MAX)
                .handshake(TokioIo::new(tcp_conn))
                .await?;
            tokio::spawn(conn);
            let req = Request::builder()
                .method(Method::GET)
                .uri(uri)
                .body(Full::new(Bytes::from(body)))?;
            let time = time
                .map(|t| Either::Left(tokio::time::sleep(t)))
                .unwrap_or(Either::Right(futures::future::pending::<()>()));
            tokio::pin!(time);
            loop {
                let second_delay = tokio::time::sleep(Duration::from_secs(1));
                let resp_futures: Vec<_> = std::iter::repeat(())
                    .take(rps)
                    .map(|_| {
                        let start = Instant::now();
                        let resp_fut = send_req.send_request(req.clone());
                        async move { (resp_fut.await, start.elapsed()) }
                    })
                    .collect();
                let all_res = select! {
                    _ = &mut ctrl_c => {
                        break;
                    },
                    _ = &mut time => {
                        break;
                    },
                    res = futures::future::join_all(resp_futures) => res,
                };
                for (res, elapsed) in all_res {
                    match res {
                        Ok(resp) => {
                            let (parts, body) = resp.into_parts();
                            tokio::pin!(body);
                            futures::future::poll_fn(move |cx| body.as_mut().poll_frame(cx)).await;
                            if !parts.status.is_success() {
                                eprintln!("server responded with error: {}", parts.status);
                                continue;
                            }
                        }
                        Err(err) => {
                            eprintln!("server responded with error: {}", err);
                            continue;
                        }
                    }
                    hist.record(elapsed.as_nanos().try_into()?)?;
                }
                select! {
                    _ = &mut ctrl_c => {
                        break;
                    },
                    _ = &mut time => {
                        break;
                    },
                    _ = second_delay => {}
                };
                println!(
                    "p50: {}, p90: {}, p99: {}",
                    humantime::format_duration(Duration::from_nanos(hist.value_at_quantile(0.50))),
                    humantime::format_duration(Duration::from_nanos(hist.value_at_quantile(0.90))),
                    humantime::format_duration(Duration::from_nanos(hist.value_at_quantile(0.99))),
                )
            }
        }
        Mode::Server { addr, payload_size } => {
            let listener = TcpListener::bind(addr).await?;
            let mut body = vec![0; payload_size];
            thread_rng().fill_bytes(&mut body);
            let resp = Response::builder()
                .status(StatusCode::OK)
                .body(Full::new(Bytes::from(body)))?;
            loop {
                let res = select! {
                    _ = &mut ctrl_c => {
                        break;
                    }
                    res = listener.accept() => {
                        res
                    }
                };
                match res {
                    Ok((stream, _)) => {
                        let resp = resp.clone();
                        println!("server handling new connection");
                        tokio::spawn(async move {
                            let mut builder =
                                server::conn::auto::Builder::new(TokioExecutor::new());
                            builder.http2().max_concurrent_streams(u32::MAX);
                            let res = builder
                                .serve_connection_with_upgrades(
                                    TokioIo::new(stream),
                                    hyper::service::service_fn(|_| {
                                        let resp = resp.clone();
                                        async move { Ok::<_, Infallible>(resp) }
                                    }),
                                )
                                .await;
                            if let Err(err) = res {
                                eprintln!("server failed to handle connection: {}", err);
                            }
                        });
                    }
                    Err(err) => {
                        eprintln!("server connect error: {}", err)
                    }
                }
            }
        }
    }
    Ok(())
}

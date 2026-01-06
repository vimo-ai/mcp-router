//! Build script for generating C headers

fn main() {
    // Generate C header using cbindgen
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_file = std::path::Path::new(&crate_dir)
        .join("include")
        .join("mcp_router_core.h");

    // Create include directory if it doesn't exist
    std::fs::create_dir_all(std::path::Path::new(&crate_dir).join("include")).ok();

    let config = cbindgen::Config::from_file("cbindgen.toml")
        .unwrap_or_default();

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
        .map(|bindings| bindings.write_to_file(&output_file))
        .ok();

    println!("cargo:rerun-if-changed=src/ffi/mod.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
}

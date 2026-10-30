#[test]
fn routers_build_from_library_target() {
    let _ = auro::api::live_router();
    let _ = auro::api::tester_router();
}

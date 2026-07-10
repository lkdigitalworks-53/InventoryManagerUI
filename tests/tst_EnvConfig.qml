import QtQuick
import QtTest
import "../qml/helper/EnvConfig.js" as Env

TestCase {
    name: "EnvConfig"

    function test_stage_maps_to_env() {
        compare(Env.envForStage("dev"), "dev")
        compare(Env.envForStage("test"), "test")
        compare(Env.envForStage("publish"), "prd")
    }

    function test_unknown_or_empty_stage_falls_back_to_prd() {
        compare(Env.envForStage(""), "prd")
        compare(Env.envForStage("garbage"), "prd")
        compare(Env.envForStage(undefined), "prd")
        compare(Env.envForStage(null), "prd")
    }

    function test_env_maps_to_database_id() {
        compare(Env.databaseIdForEnv("prd"), "(default)")
        compare(Env.databaseIdForEnv("dev"), "dev1")   // Firestore ids need >=4 chars; "dev" is invalid
        compare(Env.databaseIdForEnv("test"), "test")
    }

    function test_stage_to_database_id_end_to_end() {
        compare(Env.databaseIdForStage("publish"), "(default)")
        compare(Env.databaseIdForStage("dev"), "dev1")
        compare(Env.databaseIdForStage("test"), "test")
        compare(Env.databaseIdForStage(""), "(default)")   // fail-safe → prd → default db
    }
}

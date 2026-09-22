"""Pergunta real em pseudo-terminal; sem captura, mounts ou imagens reais."""
import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ImageNamingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pmjs-image-name-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.original_config = (ROOT / "config/image.conf").read_bytes()
        self.original_version = (ROOT / "VERSION").read_bytes()

    def tearDown(self):
        self.assertEqual((ROOT / "config/image.conf").read_bytes(), self.original_config)
        self.assertEqual((ROOT / "VERSION").read_bytes(), self.original_version)

    def run_selection(self, data=b"\n", *, terminal=True, name="pmjs-linux", body="",
                      main=False, copy_prompt=False, destination_prompt=False,
                      setup="", automount=False):
        script = '''source "$1/build-image.sh"
trap - EXIT ERR INT TERM
log_write() { :; }
IMAGE_NAME=$3
IMAGE_VERSION=0.2.0
NFS_ENABLED=1
NFS_IMAGES_DIR=""
findmnt() {
    local path=${!#} target
    case "$path" in
        "$PMJS_NAME_TEST_DIR/Ventoy com espaço/pmjs-images") target="$PMJS_NAME_TEST_DIR/Ventoy com espaço" ;;
        "$PMJS_NAME_TEST_DIR/Desmontado/pmjs-images") target=/ ;;
        *) return 1 ;;
    esac
    case "$*" in
        *'--output ID'*) printf '200\\n' ;;
        *'--output SOURCE'*) printf '/dev/sdz1\\n' ;;
        *'--output FSTYPE'*) printf 'exfat\\n' ;;
        *'--output TARGET'*) printf '%s\\n' "$target" ;;
        *) return 1 ;;
    esac
}
'''
        script += setup + "\n"
        if main:
            script += f'PMJS_TEST_AUTOMOUNT={1 if automount else 0}\n'
            script += '''eval "$(declare -f validate_config | sed '1s/validate_config/validate_config_original/')"
validate_config() {
    validate_config_original "$@" || return 1
    # As perguntas manuais continuam testando compatibilidade com config antigo.
    VENTOY_AUTOMOUNT_ENABLED=$PMJS_TEST_AUTOMOUNT
}
check_root() { :; }
check_dependencies() { :; }
resolve_project_path() { printf '%s/logs\\n' "$PMJS_NAME_TEST_DIR"; }
init_log() { :; }
select_build_destination() {
    printf 'DESTINATION_REACHED=%s-%s\\n' "$IMAGE_NAME" "$IMAGE_VERSION"
    printf 'DUAL_REACHED=%s\\n' "$BUILD_ALSO_VENTOY_DIR"
    printf 'DIRECT_REACHED=%s\\n' "$BUILD_VENTOY_DIR"
    return 1
}
detect_capture_sources() { echo 'UNEXPECTED_CAPTURE'; exit 99; }
'''
            operation = "main"
        elif copy_prompt:
            operation = "select_interactive_ventoy_copy"
        elif destination_prompt:
            operation = "select_interactive_build_destinations"
        else:
            operation = "select_build_image_version"
        script += f'''if {operation}; then status=0; else status=$?; fi
printf 'RESULT=%s-%s;SOURCE=%s;STATUS=%s\\n' "$IMAGE_NAME" "$IMAGE_VERSION" "$IMAGE_VERSION_SOURCE" "$status"
printf 'COPY_DEST=%s\\n' "$BUILD_ALSO_VENTOY_DIR"
printf 'DIRECT_DEST=%s\\n' "$BUILD_VENTOY_DIR"
'''
        script += body
        env = dict(os.environ, PMJS_NAME_TEST_DIR=str(self.directory))
        args = ["bash", "-c", script, "image-name-test", str(ROOT), str(self.directory), name]
        master = slave = None
        try:
            if terminal:
                master, slave = pty.openpty()
                process = subprocess.Popen(args, stdin=slave, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, env=env)
                os.close(slave)
                slave = None
                os.write(master, data)
                stdout, stderr = process.communicate(timeout=10)
            else:
                process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, env=env)
                stdout, stderr = process.communicate(data, timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            self.fail("A pergunta travou ou consumiu indevidamente stdin")
        finally:
            if slave is not None:
                os.close(slave)
            if master is not None:
                os.close(master)
        self.assertEqual(process.returncode, 0, stderr.decode())
        return stdout.decode(), stderr.decode()

    def test_enter_keeps_configured_default(self):
        out, err = self.run_selection()
        self.assertIn("RESULT=pmjs-linux-0.2.0;SOURCE=config/image.conf;STATUS=0", out)
        self.assertIn("[pmjs-linux-0.2.0]", err)

    def test_version_suffix(self):
        out, _ = self.run_selection(b"0.3.0-lab\n")
        self.assertIn("RESULT=pmjs-linux-0.3.0-lab;SOURCE=seleção interativa;STATUS=0", out)

    def test_full_name_without_duplicate_prefix(self):
        out, _ = self.run_selection(b"pmjs-linux-0.3.0\n")
        self.assertIn("RESULT=pmjs-linux-0.3.0;", out)

    def test_configured_prefix(self):
        out, _ = self.run_selection(b"pmjs-lab-1.0\n", name="pmjs-lab")
        self.assertIn("RESULT=pmjs-lab-1.0;", out)

    def test_unsafe_values_reprompt(self):
        unsafe = ["../bad", "/tmp/image", ".hidden", "-bad", "foo/bar", "foo bar", "pmjs-linux-"]
        out, err = self.run_selection(("\n".join(unsafe + ["0.4.0"]) + "\n").encode())
        self.assertEqual(err.count("Versão/sufixo inválido"), len(unsafe))
        self.assertIn("RESULT=pmjs-linux-0.4.0;", out)

    def test_eof_cancels_without_changing_version(self):
        out, err = self.run_selection(b"\x04")
        self.assertIn("STATUS=1", out)
        self.assertIn("RESULT=pmjs-linux-0.2.0;", out)
        self.assertIn("build não iniciado", err)

    def test_noninteractive_preserves_config_and_does_not_consume_pipe(self):
        out, err = self.run_selection(b"pipe-data\n", terminal=False,
                                      body='read -r remaining; printf "UNREAD=%s\\n" "$remaining"\n')
        self.assertIn("RESULT=pmjs-linux-0.2.0;SOURCE=config/image.conf;STATUS=0", out)
        self.assertIn("UNREAD=pipe-data", out)
        self.assertNotIn("Versão/sufixo", err)

    def test_main_cancelled_before_log_directory_destination_or_capture(self):
        out, _ = self.run_selection(b"\x04", main=True)
        self.assertIn("STATUS=1", out)
        self.assertNotIn("DESTINATION_REACHED", out)
        self.assertNotIn("UNEXPECTED_CAPTURE", out)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_main_passes_chosen_version_to_destination(self):
        out, _ = self.run_selection(b"0.5.0\nn\n", main=True)
        self.assertIn("DESTINATION_REACHED=pmjs-linux-0.5.0", out)
        self.assertNotIn("UNEXPECTED_CAPTURE", out)

    def ventoy_fixture(self):
        destination = self.directory / "Ventoy com espaço/pmjs-images"
        destination.mkdir(parents=True)
        return destination

    def test_launcher_default_yes_asks_explicit_ventoy_path(self):
        destination = self.ventoy_fixture()
        out, err = self.run_selection(f"\n{destination}\n".encode(), copy_prompt=True)
        self.assertIn(f"COPY_DEST={destination}\n", out)
        self.assertIn("[S/n]", err)
        self.assertIn("Diretório pmjs-images do Ventoy", err)
        self.assertEqual(list(destination.iterdir()), [])

    def test_launcher_explicit_yes(self):
        destination = self.ventoy_fixture()
        out, _ = self.run_selection(f"sim\n{destination}\n".encode(), copy_prompt=True)
        self.assertIn(f"COPY_DEST={destination}\n", out)

    def test_launcher_automount_enabled_skips_path_prompt(self):
        out, err = self.run_selection(b"\n", copy_prompt=True, setup="VENTOY_AUTOMOUNT_ENABLED=1")
        self.assertIn("COPY_DEST=auto\n", out)
        self.assertNotIn("Diretório pmjs-images do Ventoy", err)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_main_launcher_menu_asks_path_even_with_automount_enabled(self):
        destination = self.ventoy_fixture()
        out, err = self.run_selection(f"0.8.0\n3\n{destination}\n".encode(),
                                      main=True, automount=True)
        self.assertIn(f"DUAL_REACHED={destination}\n", out)
        self.assertIn("Diretório pmjs-images do Ventoy", err)

    def test_launcher_media_changed_after_selection_rejected_before_build(self):
        destination = self.ventoy_fixture()
        (self.directory / "nfs").mkdir()
        body = '''BUILD_NFS_DIR="$2/nfs"
read_dual_build_nfs_identity() {
    printf '100 192.168.0.19:/var/clone-pmjs nfs4 %s\\n' "$BUILD_DUAL_NFS_DIR"
}
eval "$(declare -f findmnt | sed '1s/findmnt/findmnt_original/')"
findmnt() {
    case "$*" in
        *'--output ID'*) printf '999\\n' ;;
        *) findmnt_original "$@" ;;
    esac
}
if prepare_build_ventoy_copy; then exit 99; fi
'''
        _, err = self.run_selection(f"\n{destination}\n".encode(), copy_prompt=True, body=body)
        self.assertIn("O mount do Ventoy mudou após a seleção interativa", err)
        self.assertEqual(list(destination.iterdir()), [])

    def test_launcher_no_keeps_nfs_only(self):
        out, err = self.run_selection(b"n\n", copy_prompt=True)
        self.assertIn("Destino selecionado: somente NFS", out)
        self.assertIn("COPY_DEST=\n", out)
        self.assertNotIn("Diretório pmjs-images do Ventoy", err)

    def test_launcher_invalid_answer_reprompts(self):
        out, err = self.run_selection(b"talvez\nn\n", copy_prompt=True)
        self.assertIn("Responda S", err)
        self.assertEqual(err.count("[S/n]"), 2)
        self.assertIn("COPY_DEST=\n", out)

    def test_launcher_empty_unsafe_and_unmounted_paths_reprompt(self):
        destination = self.ventoy_fixture()
        unmounted = self.directory / "Desmontado/pmjs-images"
        unmounted.mkdir(parents=True)
        out, err = self.run_selection(f"s\n\n/\n{unmounted}\n{destination}\n".encode(), copy_prompt=True)
        self.assertIn("O caminho do Ventoy é obrigatório", err)
        self.assertIn("Ventoy não parece estar montado", err)
        self.assertIn(f"COPY_DEST={destination}\n", out)
        self.assertEqual(list(destination.iterdir()), [])

    def test_launcher_eof_on_copy_question_cancels(self):
        out, err = self.run_selection(b"\x04", copy_prompt=True)
        self.assertIn("STATUS=1", out)
        self.assertIn("COPY_DEST=\n", out)
        self.assertIn("build não iniciado", err)

    def test_launcher_eof_on_path_question_cancels(self):
        out, err = self.run_selection(b"\n\x04", copy_prompt=True)
        self.assertIn("STATUS=1", out)
        self.assertIn("COPY_DEST=\n", out)
        self.assertIn("build não iniciado", err)

    def test_launcher_explicit_options_and_local_mode_skip_copy_prompt(self):
        for setup in ('BUILD_ALSO_VENTOY_DIR=/explicit/pmjs-images',
                      'BUILD_VENTOY_DIR=/direct/pmjs-images', 'NFS_ENABLED=0'):
            with self.subTest(setup=setup):
                out, err = self.run_selection(b"unread-data\n", copy_prompt=True, setup=setup,
                                              body='read -r remaining; printf "UNREAD=%s\\n" "$remaining"\n')
                self.assertIn("UNREAD=unread-data", out)
                self.assertNotIn("[S/n]", err)

    def test_launcher_legacy_or_explicit_nfs_offers_copy(self):
        destination = self.ventoy_fixture()
        for setup in ('NFS_ENABLED=0; NFS_IMAGES_DIR=/legacy',
                      'NFS_ENABLED=0; BUILD_NFS_DIR=/explicit'):
            with self.subTest(setup=setup):
                out, err = self.run_selection(f"\n{destination}\n".encode(), copy_prompt=True, setup=setup)
                self.assertIn(f"COPY_DEST={destination}\n", out)
                self.assertIn("[S/n]", err)

    def test_noninteractive_skips_copy_question_without_consuming_stdin(self):
        out, err = self.run_selection(b"pipe-data\n", terminal=False, copy_prompt=True,
                                      body='read -r remaining; printf "UNREAD=%s\\n" "$remaining"\n')
        self.assertIn("COPY_DEST=\n", out)
        self.assertIn("UNREAD=pipe-data", out)
        self.assertNotIn("[S/n]", err)

    def test_main_launcher_passes_interactive_copy_to_preflight(self):
        destination = self.ventoy_fixture()
        out, _ = self.run_selection(f"0.8.0\n3\n{destination}\n".encode(), main=True)
        self.assertIn("DESTINATION_REACHED=pmjs-linux-0.8.0", out)
        self.assertIn(f"DUAL_REACHED={destination}\n", out)
        self.assertNotIn("UNEXPECTED_CAPTURE", out)

    def test_main_launcher_passes_direct_ventoy_to_preflight(self):
        destination = self.ventoy_fixture()
        out, _ = self.run_selection(f"0.8.1\n2\n{destination}\n".encode(), main=True)
        self.assertIn("DESTINATION_REACHED=pmjs-linux-0.8.1", out)
        self.assertIn(f"DIRECT_REACHED={destination}\n", out)
        self.assertIn("DUAL_REACHED=\n", out)
        self.assertNotIn("UNEXPECTED_CAPTURE", out)

    def test_main_launcher_cancels_before_mounts_logs_or_capture(self):
        for data in (b"0.8.0\n\x04", b"0.8.0\n2\n\x04", b"0.8.0\n3\n\x04"):
            with self.subTest(data=data):
                out, _ = self.run_selection(data, main=True)
                self.assertIn("STATUS=1", out)
                self.assertNotIn("DESTINATION_REACHED", out)
                self.assertNotIn("UNEXPECTED_CAPTURE", out)
                self.assertEqual(list(self.directory.iterdir()), [])

    def test_destination_menu_defaults_to_nfs(self):
        out, err = self.run_selection(b"\n", destination_prompt=True)
        self.assertIn("Destino selecionado: somente NFS", out)
        self.assertIn("Onde deseja publicar", out)
        self.assertIn("Escolha [1]", err)
        self.assertIn("DIRECT_DEST=\n", out)
        self.assertIn("COPY_DEST=\n", out)

    def test_destination_menu_direct_ventoy_asks_and_validates_path(self):
        destination = self.ventoy_fixture()
        out, err = self.run_selection(f"2\n{destination}\n".encode(),
                                      destination_prompt=True,
                                      setup="VENTOY_AUTOMOUNT_ENABLED=1")
        self.assertIn(f"DIRECT_DEST={destination}\n", out)
        self.assertIn("COPY_DEST=\n", out)
        self.assertIn("Diretório pmjs-images do Ventoy", err)
        self.assertNotIn("Ventoy automático", out)
        self.assertEqual(list(destination.iterdir()), [])

    def test_destination_menu_both_asks_path(self):
        destination = self.ventoy_fixture()
        out, err = self.run_selection(f"3\n{destination}\n".encode(),
                                      destination_prompt=True)
        self.assertIn(f"COPY_DEST={destination}\n", out)
        self.assertIn("DIRECT_DEST=\n", out)
        self.assertIn("NFS + Ventoy", out)
        self.assertIn("Diretório pmjs-images do Ventoy", err)

    def test_destination_menu_reprompts_invalid_choice_and_missing_nfs(self):
        destination = self.ventoy_fixture()
        out, err = self.run_selection(f"talvez\n1\n3\n2\n{destination}\n".encode(),
                                      destination_prompt=True,
                                      setup="NFS_ENABLED=0; NFS_IMAGES_DIR=''")
        self.assertIn("Opção inválida", err)
        self.assertIn("Destino NFS não está configurado", err)
        self.assertIn("A opção ambos exige", err)
        self.assertEqual(out.count("Onde deseja publicar"), 4)
        self.assertIn(f"DIRECT_DEST={destination}\n", out)

    def test_destination_menu_explicit_ventoy_options_skip_prompt(self):
        for setup in ("BUILD_VENTOY_DIR=/explicit/pmjs-images",
                      "BUILD_ALSO_VENTOY_DIR=/explicit/pmjs-images"):
            with self.subTest(setup=setup):
                out, err = self.run_selection(
                    b"unread-data\n", destination_prompt=True, setup=setup,
                    body='read -r remaining; printf "UNREAD=%s\\n" "$remaining"\n')
                self.assertIn("UNREAD=unread-data", out)
                self.assertNotIn("Onde deseja publicar", out)
                self.assertNotIn("Escolha [1]", err)

    def test_destination_menu_noninteractive_does_not_consume_stdin(self):
        out, err = self.run_selection(
            b"pipe-data\n", terminal=False, destination_prompt=True,
            body='read -r remaining; printf "UNREAD=%s\\n" "$remaining"\n')
        self.assertIn("UNREAD=pipe-data", out)
        self.assertNotIn("Onde deseja publicar", out)
        self.assertNotIn("Escolha [1]", err)

    def test_chosen_version_in_workspace_and_schema1_manifest(self):
        (self.directory / "output").mkdir()
        source = self.directory / "source/etc"
        source.mkdir(parents=True)
        (source / "os-release").write_text('PRETTY_NAME="PMJS Naming Test"\n')
        body = '''workspace=""; final=""
prepare_build_workspace "$2/output" "$IMAGE_NAME-$IMAGE_VERSION" workspace final
printf 'WORKSPACE=%s\\nFINAL=%s\\n' "$workspace" "$final"
# Synthetic bytes suffice here: test manifest metadata, not archive generation.
printf 'root-fixture' > "$workspace/rootfs.tar.zst"
printf 'home-fixture' > "$workspace/homefs.tar.zst"
builder_version=""
load_builder_version "$1/VERSION" builder_version
generate_manifest "$workspace/manifest.json" "$IMAGE_NAME" "$IMAGE_VERSION" \
    "$builder_version" zstd "$workspace/rootfs.tar.zst" "$workspace/homefs.tar.zst" "$2/source"
validate_manifest "$workspace/manifest.json" "$workspace/rootfs.tar.zst" "$workspace/homefs.tar.zst" zstd
'''
        out, _ = self.run_selection(b"pmjs-linux-0.6.0\n", body=body)
        self.assertIn(".pmjs-linux-0.6.0.build.", out)
        self.assertFalse((self.directory / "output/pmjs-linux-0.6.0").exists())
        manifests = list((self.directory / "output").glob(".pmjs-linux-0.6.0.build.*/manifest.json"))
        self.assertEqual(len(manifests), 1)
        manifest = json.loads(manifests[0].read_text())
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["image_name"], "pmjs-linux")
        self.assertEqual(manifest["image_version"], "0.6.0")
        self.assertEqual(manifest["builder_version"], self.original_version.decode().strip())

    def test_existing_selected_version_remains_immutable(self):
        final = self.directory / "output/pmjs-linux-0.7.0"
        final.mkdir(parents=True)
        marker = final / "unchanged"
        marker.write_text("existing version\n")
        body = '''workspace=""; final=""
if prepare_build_workspace "$2/output" "$IMAGE_NAME-$IMAGE_VERSION" workspace final; then
    exit 99
fi
'''
        self.run_selection(b"0.7.0\n", body=body)
        self.assertEqual(marker.read_text(), "existing version\n")
        self.assertEqual(list(final.parent.iterdir()), [final])


if __name__ == "__main__":
    unittest.main(verbosity=2)

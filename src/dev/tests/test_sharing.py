import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sharing
import volumes


class SharingTests(unittest.TestCase):
    def test_cloned_clients_have_stable_distinct_protocol_identities(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('sharing.Session') as session:
            session.return_value.metadata = {'user':'ubuntu'}
            first = sharing.guest_config(Path(directory)/'one', {'id':'a'*32})['client_id']
            again = sharing.guest_config(Path(directory)/'one', {'id':'b'*32})['client_id']
            other = sharing.guest_config(Path(directory)/'two', {'id':'a'*32})['client_id']
            self.assertEqual(first, again)
            self.assertNotEqual(first, other)
            self.assertEqual(len(first), 64)

    def test_locked_client_never_installs_missing_prerequisites(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory); (vm/'uvm.lock.json').write_text('{}')
            with mock.patch('sharing.files.agent', return_value='missing'), mock.patch('sharing.files.upload') as upload:
                with self.assertRaisesRegex(ValueError, 'sharing profile'): sharing.install_client(mock.Mock(vm=vm))
                upload.assert_not_called()

    def test_first_connection_mounts_even_when_monotonic_clock_starts_at_zero(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory); (vm/'logs').mkdir(); (vm/'sockets').mkdir()
            row = {'id':'a'*32, 'port':50001, 'folder':'Personal'}
            session = mock.Mock(vm=vm, managed=True)
            process = mock.Mock(); process.poll.return_value = None
            polls = []
            def run(argv, **kwargs):
                if argv[0] == 'ps':
                    polls.append(True)
                    return subprocess.CompletedProcess(argv, 0 if len(polls) == 1 else 1, 'file=' + str(vm/'disk.img') + ',', '')
                return subprocess.CompletedProcess(argv, 0, '', '')
            with mock.patch('sharing.Session', return_value=session), mock.patch('sharing.rt.sockets', return_value=vm/'sockets'), \
                 mock.patch('sharing.clients', return_value=[row]), mock.patch('sharing.root_ssh', return_value=['ssh','root@127.0.0.1']), \
                 mock.patch('sharing.descriptor', return_value=(vm, {}, {'nfs_port':50002}, vm/'server')), \
                 mock.patch('sharing.server_tunnel'), mock.patch('sharing.install_client'), \
                 mock.patch('sharing.subprocess.run', side_effect=run), mock.patch('sharing.subprocess.Popen', return_value=process), \
                 mock.patch('sharing.time.monotonic', return_value=0), mock.patch('sharing.time.sleep'), mock.patch('sharing.guest') as guest:
                sharing.watch(vm, None, 1234)
            guest.assert_any_call(session, 'mount', row)

    def test_client_settings_are_bounded_and_reject_path_traversal_and_duplicate_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory)
            row = {'id':'a' * 32, 'port':40000, 'folder':'Personal-aabbcc'}
            for rows in ([{**row, 'folder':'../outside'}], [row] * 17, [row, {**row, 'id':'b' * 32}]):
                (vm/sharing.CLIENTS).write_text(json.dumps({'schema':1, 'folders':rows}))
                with self.assertRaises(ValueError): sharing.clients(vm)
            (vm/sharing.CLIENTS).write_text(json.dumps({'schema':1, 'folders':[row]}))
            self.assertIn('type=11,value=uvm.shared=' + 'a'*32, sharing.arguments(vm))

    def test_direct_disk_attachment_cannot_steal_a_shared_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();vm=root/'OmacVM Test-client';vm.mkdir()
            (vm/'vm.env').write_text('VM_USER=ubuntu\nSSH_PORT=52223\n');(vm/'guest-os').write_text('ubuntu');(vm/'disk.img').touch()
            record=volumes.create(vm,'Shared',4)
            server=root/'.ubuntu-services'/'Files';server.mkdir(parents=True)
            folder,_=volumes.volume(vm,record['id'])
            record.update(shared=True,attached_vm=str(server))
            (folder/'volume.json').write_text(json.dumps(record))
            with mock.patch('volumes.maintenance') as maintenance:
                with self.assertRaisesRegex(ValueError,'Shared Folders'): volumes.prepare(vm,record['id'],['Projects'])
                maintenance.assert_not_called()

    def test_file_service_cannot_stop_with_a_running_client(self):
        with tempfile.TemporaryDirectory() as directory:
            client=Path(directory)
            with mock.patch('sharing.descriptor',return_value=(None,None,{'clients':[str(client)]},client/'server')), \
                 mock.patch('sharing.volumes.idle',side_effect=ValueError('stop the VM')), mock.patch('sharing.rt.stop') as stop:
                with self.assertRaises(ValueError): sharing.stop(client,'a'*32)
                stop.assert_not_called()

    def test_file_service_metadata_cannot_escape_private_service_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            vm=Path(directory).resolve()/'OmacVM Test-client';vm.mkdir()
            record=volumes.create(vm,'Shared',4);folder,_=volumes.volume(vm,record['id'])
            (folder/'sharing.json').write_text(json.dumps({'schema':1,'id':record['id'],'server':'/tmp/unrelated'}))
            with self.assertRaisesRegex(ValueError,'invalid'): sharing.descriptor(vm,record['id'])


if __name__ == '__main__': unittest.main()

import json, os, pathlib, subprocess, tempfile, threading, time, unittest
CLIENT = pathlib.Path(__file__).resolve().parents[1] / 'bin/quickshotctl'

class ClientTests(unittest.TestCase):
    def invoke(self, arguments, response=None):
        with tempfile.TemporaryDirectory() as home:
            root = pathlib.Path(home) / 'Library/Application Support/QuickShot/Control'
            observed = []
            def service():
                end=time.monotonic()+3
                while time.monotonic()<end:
                    files=list(root.glob('*.request.json'))
                    if files:
                        path=files[0]; observed.append(json.loads(path.read_text()))
                        if response is not None:
                            path.with_name(path.name.replace('.request.json','.response.json')).write_text(json.dumps(response))
                        return
                    time.sleep(.01)
            worker=threading.Thread(target=service);worker.start()
            result=subprocess.run([str(CLIENT),'--timeout','0.5',*arguments],env={**os.environ,'HOME':home},capture_output=True,text=True)
            worker.join()
            leftovers=list(root.glob('*.json'))
            self.assertEqual(leftovers,[])
            return result,observed

    def test_start_request_and_confirmed_response(self):
        result,requests=self.invoke(['start','--display','1','--rect','0','90','800','600','--output','/tmp/demo.mp4'],{'ok':True,'state':'recording','path':'/tmp/demo.mp4'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['state'],'recording')
        self.assertEqual(requests[0]['rect'],[0,90,800,600])
        self.assertEqual(requests[0]['display'],1)
        self.assertGreater(requests[0]['expires'],time.time()-1)

    def test_context_request_names_the_app_and_returns_the_reading(self):
        result,requests=self.invoke(['context','--app','Chrome'],{'ok':True,'app':'Google Chrome','title':'Pricing','location':'localhost:3000/pricing'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['location'],'localhost:3000/pricing')
        self.assertEqual(requests[0]['command'],'context')
        self.assertEqual(requests[0]['app'],'Chrome')

    def test_context_without_app_sends_no_filter(self):
        _,requests=self.invoke(['context'],{'ok':True,'app':'Finder','title':''})
        self.assertNotIn('app',requests[0])

    def test_rejection_is_not_reported_as_success(self):
        result,_=self.invoke(['stop'],{'ok':False,'error':'No recording is active'})
        self.assertEqual(result.returncode,1)
        self.assertEqual(json.loads(result.stdout)['error'],'No recording is active')

    def test_no_acknowledgement_times_out_and_removes_request(self):
        result,requests=self.invoke(['status'])
        self.assertEqual(result.returncode,1)
        self.assertEqual(len(requests),1)
        self.assertIn('did not respond',result.stderr)

    def test_display_without_region_is_rejected_before_dispatch(self):
        result,requests=self.invoke(['start','--display','1','--output','/tmp/demo.mp4'])
        self.assertEqual(result.returncode,2)
        self.assertEqual(requests,[])
        self.assertIn('--display requires --rect',result.stderr)

if __name__=='__main__': unittest.main()

import json, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", ".."))
from tools.gen import main as gen_main  # noqa: E402


SPEC = {
    "openapi": "3.1.0",
    "info": {"title": "t", "version": "0"},
    "paths": {
        "/headers": {
            "get": {
                "operationId": "getHeaders",
                "x-moonbit-include": True,
                "responses": {"200": {"content": {"application/json": {"schema": {"type": "object", "x-moonbit-json": True}}}}},
            }
        }
    },
}


class MinimalSliceTest(unittest.TestCase):
    def test_no_path_params_omits_percent_encode_and_sdkjson(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = os.path.join(tmp, "spec.json")
            with open(spec, "w") as f:
                json.dump(SPEC, f)
            out = os.path.join(tmp, "out")
            code = gen_main.run(["--spec", spec, "--out", out, "--package", "x/gen"])
            self.assertEqual(code, 0)
            with open(os.path.join(out, "operations.mbt"), encoding="utf-8") as stream:
                ops = stream.read()
            with open(os.path.join(out, "moon.pkg"), encoding="utf-8") as stream:
                pkg = stream.read()
            self.assertNotIn("fn percent_encode", ops)
            self.assertNotIn("@sdkjson", pkg)
            self.assertIn("get_headers_decode", ops)


if __name__ == "__main__":
    unittest.main()

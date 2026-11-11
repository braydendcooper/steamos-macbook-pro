import unittest

from osinstall import esp_chosen_vars, esp_uuid_from_vars, normalize_esp_vars


class ESPChosenVarsTests(unittest.TestCase):
    def test_chosen_vars_lowercase_and_order(self):
        self.assertEqual(esp_chosen_vars("ABCD-1234-EFAB"), [
            "chosen.gravity,efi-system-partition=abcd-1234-efab",
            "chosen.asahi,efi-system-partition=abcd-1234-efab",
        ])

    def test_gravity_only(self):
        self.assertEqual(esp_uuid_from_vars([
            "chosen.gravity,efi-system-partition=gravity-uuid",
        ]), "gravity-uuid")

    def test_asahi_only(self):
        self.assertEqual(esp_uuid_from_vars([
            "chosen.asahi,efi-system-partition=asahi-uuid",
        ]), "asahi-uuid")

    def test_gravity_preferred(self):
        for vars in (["chosen.gravity,efi-system-partition=gravity-uuid",
                      "chosen.asahi,efi-system-partition=asahi-uuid"],
                     ["chosen.asahi,efi-system-partition=asahi-uuid",
                      "chosen.gravity,efi-system-partition=gravity-uuid"]):
            with self.subTest(vars=vars):
                self.assertEqual(esp_uuid_from_vars(vars), "gravity-uuid")

    def test_neither(self):
        self.assertIsNone(esp_uuid_from_vars(["chainload=uuid;boot.bin"]))
        self.assertIsNone(esp_uuid_from_vars([]))

    def test_value_with_equals(self):
        self.assertEqual(esp_uuid_from_vars([
            "chainload=uuid;boot=next.bin",
            "chosen.asahi,efi-system-partition=uuid=extra",
        ]), "uuid=extra")

    def test_var_without_equals(self):
        self.assertEqual(esp_uuid_from_vars([
            "chosen.gravity,efi-system-partition",
            "chosen.asahi,efi-system-partition=asahi-uuid",
        ]), "asahi-uuid")
        self.assertIsNone(esp_uuid_from_vars(["malformed"]))

    def test_normalize_gravity_only(self):
        vars = ["chosen.gravity,efi-system-partition=UUID", "chainload=uuid;boot.bin"]
        original = list(vars)
        self.assertEqual(normalize_esp_vars(vars), [
            "chosen.gravity,efi-system-partition=uuid",
            "chosen.asahi,efi-system-partition=uuid",
            "chainload=uuid;boot.bin",
        ])
        self.assertEqual(vars, original)

    def test_normalize_asahi_only(self):
        self.assertEqual(normalize_esp_vars([
            "display=retina",
            "chosen.asahi,efi-system-partition=UUID",
            "chainload=uuid;boot.bin",
        ]), [
            "display=retina",
            "chosen.gravity,efi-system-partition=uuid",
            "chosen.asahi,efi-system-partition=uuid",
            "chainload=uuid;boot.bin",
        ])

    def test_normalize_both_orders_and_duplicates(self):
        gravity = "chosen.gravity,efi-system-partition=GRAVITY-UUID"
        asahi = "chosen.asahi,efi-system-partition=ASAHI-UUID"
        for esp_vars in ([gravity, asahi], [asahi, gravity],
                         [asahi, gravity, asahi, gravity]):
            with self.subTest(esp_vars=esp_vars):
                self.assertEqual(normalize_esp_vars([
                    "display=retina", *esp_vars, "chainload=uuid;boot.bin",
                ]), [
                    "display=retina",
                    "chosen.gravity,efi-system-partition=gravity-uuid",
                    "chosen.asahi,efi-system-partition=gravity-uuid",
                    "chainload=uuid;boot.bin",
                ])

    def test_normalize_without_esp_returns_copy(self):
        for vars in ([], ["display=retina", "chainload=uuid;boot=next.bin",
                          "chosen.gravity,efi-system-partition", "malformed"]):
            with self.subTest(vars=vars):
                normalized = normalize_esp_vars(vars)
                self.assertEqual(normalized, vars)
                self.assertIsNot(normalized, vars)

    def test_normalize_preserves_other_vars_and_first_esp_position(self):
        self.assertEqual(normalize_esp_vars([
            "chosen.asahi,m1n1-stage1-version=1.2.3",
            "chosen.gravity,efi-system-partition",
            "chosen.asahi,efi-system-partition=ASAHI-UUID",
            "display=retina",
            "chosen.gravity,efi-system-partition=GRAVITY-UUID",
            "chainload=uuid;boot=next.bin",
            "malformed",
        ]), [
            "chosen.asahi,m1n1-stage1-version=1.2.3",
            "chosen.gravity,efi-system-partition",
            "chosen.gravity,efi-system-partition=gravity-uuid",
            "chosen.asahi,efi-system-partition=gravity-uuid",
            "display=retina",
            "chainload=uuid;boot=next.bin",
            "malformed",
        ])


if __name__ == "__main__":
    unittest.main()

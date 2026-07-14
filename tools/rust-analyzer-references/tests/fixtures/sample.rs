pub fn unused_public() {}

pub fn used_public() {}

pub struct OneUse;

pub struct TwoUse;

struct PrivateType;

pub struct Widget;

impl Widget {
  pub fn method() {}
}

fn exercise() {
  let _ = "🦀"; used_public();
  let _one = OneUse;
  let _two_a = TwoUse;
  let _two_b = TwoUse;
}

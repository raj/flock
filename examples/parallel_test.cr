# Parallel scheduler demo (headless, no GPU).
#
# Three systems write three DISJOINT component types, so the scheduler places them in one
# wave and (on an MT build) runs them on separate threads. Each system does a chunk of
# CPU work per entity so the overlap is measurable.
#
#   crystal run --release examples/parallel_test.cr                 # sequential fallback
#   crystal run --release -Dpreview_mt examples/parallel_test.cr    # real threads
#
# Prints the wave plan + sequential-vs-parallel timings, checks both produce identical
# results, and exits 0 on success (1 otherwise).
require "../src/flock"

struct A
  include Flock::Component
  property v : Float64 = 0.0

  def initialize(@v : Float64 = 0.0)
  end
end

struct B
  include Flock::Component
  property v : Float64 = 0.0

  def initialize(@v : Float64 = 0.0)
  end
end

struct C
  include Flock::Component
  property v : Float64 = 0.0

  def initialize(@v : Float64 = 0.0)
  end
end

ENTITIES = 1_200
FRAMES   =    20

# A deliberately expensive per-entity computation so threads have real work to overlap.
def crunch(x : Float64) : Float64
  acc = x
  600.times { |i| acc = Math.sqrt(acc * acc + 1.0) - Math.sin(acc + i) * 0.0 }
  acc + 1.0
end

def build(parallel : Bool) : Flock::App
  app = Flock::App.new
  app.parallel = parallel
  app.add_startup do |_w, cmd|
    ENTITIES.times { cmd.spawn(A.new(1.0), B.new(2.0), C.new(3.0)) }
  end
  app.add_system(Flock::Schedule::Update, label: :sysA, writes: {A}) do |w, _c|
    w.query(A) { |_e, p| p.value.v = crunch(p.value.v) }
  end
  app.add_system(Flock::Schedule::Update, label: :sysB, writes: {B}) do |w, _c|
    w.query(B) { |_e, p| p.value.v = crunch(p.value.v) }
  end
  app.add_system(Flock::Schedule::Update, label: :sysC, writes: {C}) do |w, _c|
    w.query(C) { |_e, p| p.value.v = crunch(p.value.v) }
  end
  app
end

def snapshot(app : Flock::App) : Tuple(Float64, Float64, Float64)
  a = b = c = 0.0
  app.world.query(A, B, C) do |_e, pa, pb, pc|
    a += pa.value.v; b += pb.value.v; c += pc.value.v
  end
  {a, b, c}
end

mt = {{ flag?(:preview_mt) || flag?(:execution_context) }}
puts "build: #{mt ? "MT (real threads)" : "single-thread (sequential fallback)"}"

plan = build(true).parallel_plan(Flock::Schedule::Update)
puts "Update wave plan: #{plan.map(&.map(&.to_s))}"

seq = build(false)
seq.run_headless(1) # warm (startup + first frame)
t0 = Time.instant
seq.run_headless(FRAMES)
seq_dt = Time.instant - t0

par = build(true)
par.run_headless(1)
t1 = Time.instant
par.run_headless(FRAMES)
par_dt = Time.instant - t1

puts "sequential: #{seq_dt.total_milliseconds.round(1)} ms"
puts "parallel:   #{par_dt.total_milliseconds.round(1)} ms"
puts "speedup:    #{(seq_dt.total_milliseconds / par_dt.total_milliseconds).round(2)}x"

s = snapshot(seq)
p = snapshot(par)
ok = s == p
puts ok ? "results identical ✓  (A=#{s[0].round(2)} B=#{s[1].round(2)} C=#{s[2].round(2)})" \
        : "MISMATCH: seq=#{s} par=#{p}"
exit(ok ? 0 : 1)

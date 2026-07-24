module Flock
  # A small declarative render graph. Declare named texture resources and nodes that read /
  # write them; the graph topologically orders nodes by their resource dependencies, allocates
  # the transient textures from a pool that ALIASES resources whose lifetimes don't overlap
  # (fewer physical textures than logical), and runs each node with resolved views.
  #
  #   g = Flock::RenderGraph.new(gpu)
  #   g.import("surface", surface_view)                      # external output
  #   g.texture("hdr", w, h, fmt)                            # transient
  #   g.node("geo",   writes: ["hdr"]) { |c| draw_into(c.view("hdr")) }
  #   g.node("post",  reads: ["hdr"], writes: ["surface"]) { |c| blit(c.view("hdr"), c.view("surface")) }
  #   stats = g.run
  #
  # Rules: each transient resource has exactly ONE writer node (single-assignment DAG); readers
  # depend on that writer. Imported resources (a surface / offscreen view supplied by the app)
  # are never pooled. Native only (uses PostTarget for the pool).
  class RenderGraph
    record ResSpec, name : String, w : UInt32, h : UInt32, format : LibWGPU::TextureFormat

    class GraphNode
      getter name : String
      getter reads : Array(String)
      getter writes : Array(String)
      getter exec : GraphContext ->

      def initialize(@name, @reads, @writes, @exec)
      end
    end

    # Passed to each node's block; resolves a resource name to its (pooled or imported) view.
    class GraphContext
      def initialize(@views : Hash(String, LibWGPU::TextureView))
      end

      def view(name : String) : LibWGPU::TextureView
        @views[name]? || raise "render graph: node used undeclared resource '#{name}'"
      end
    end

    record Stats, order : Array(String), transient_logical : Int32, transient_physical : Int32

    @specs = {} of String => ResSpec
    @imported = {} of String => LibWGPU::TextureView
    @nodes = [] of GraphNode

    def initialize(@gpu : GpuContext)
    end

    # Registers a transient texture resource (allocated + possibly aliased by `run`).
    def texture(name : String, w : Int, h : Int, format : LibWGPU::TextureFormat) : self
      @specs[name] = ResSpec.new(name, w.to_u32, h.to_u32, format)
      self
    end

    # Registers an externally-owned view (surface / offscreen target) — never pooled.
    def import(name : String, view : LibWGPU::TextureView) : self
      @imported[name] = view
      self
    end

    def node(name : String, reads : Array(String) = [] of String,
             writes : Array(String) = [] of String, &block : GraphContext ->) : self
      @nodes << GraphNode.new(name, reads, writes, block)
      self
    end

    # Orders the nodes, allocates/aliases the transient textures, runs each node, frees the
    # pool. Returns stats (execution order + logical vs physical transient count).
    def run : Stats
      order = topo_order
      writer = writer_index(order)
      first, last = lifetimes(order, writer)
      assign, physicals = allocate(first, last)

      views = {} of String => LibWGPU::TextureView
      @imported.each { |name, v| views[name] = v }
      assign.each { |res, phys| views[res] = physicals[phys].view }
      ctx = GraphContext.new(views)

      order.each { |n| find_node(n).exec.call(ctx) }

      physicals.each &.release
      Stats.new(order, @specs.size, physicals.size)
    end

    # Kahn topological sort: a node depends on the writer of every resource it reads. Stable
    # (registration order on ties). Raises on a cycle or a resource with two writers.
    private def topo_order : Array(String)
      idx = {} of String => Int32
      @nodes.each_with_index { |n, i| idx[n.name] = i }

      writes_by = {} of String => String
      @nodes.each do |n|
        n.writes.each do |r|
          if prev = writes_by[r]?
            raise "render graph: resource '#{r}' written by both '#{prev}' and '#{n.name}'"
          end
          writes_by[r] = n.name
        end
      end

      indeg = Array(Int32).new(@nodes.size, 0)
      succ = Array(Array(Int32)).new(@nodes.size) { [] of Int32 }
      @nodes.each_with_index do |n, i|
        n.reads.each do |r|
          if w = writes_by[r]?
            j = idx[w]
            next if j == i
            succ[j] << i
            indeg[i] += 1
          end
        end
      end

      ready = (0...@nodes.size).select { |i| indeg[i] == 0 }
      out = [] of String
      until ready.empty?
        i = ready.min
        ready.delete(i)
        out << @nodes[i].name
        succ[i].each do |j|
          indeg[j] -= 1
          ready << j if indeg[j] == 0
        end
      end
      raise "render graph: cycle detected" unless out.size == @nodes.size
      out
    end

    private def writer_index(order : Array(String)) : Hash(String, Int32)
      pos = {} of String => Int32
      order.each_with_index { |name, i| pos[name] = i }
      w = {} of String => Int32
      @nodes.each { |n| n.writes.each { |r| w[r] = pos[n.name] } }
      w
    end

    # First/last node position (in `order`) that touches each transient resource.
    private def lifetimes(order : Array(String), writer : Hash(String, Int32)) : Tuple(Hash(String, Int32), Hash(String, Int32))
      pos = {} of String => Int32
      order.each_with_index { |name, i| pos[name] = i }
      first = {} of String => Int32
      last = {} of String => Int32
      @specs.each_key do |r|
        f = writer[r]? || pos[find_first_user(r)]
        first[r] = f
        last[r] = f
      end
      @nodes.each do |n|
        p = pos[n.name]
        (n.reads + n.writes).each do |r|
          next unless @specs.has_key?(r)
          first[r] = p if !first.has_key?(r) || p < first[r]
          last[r] = p if !last.has_key?(r) || p > last[r]
        end
      end
      {first, last}
    end

    private def find_first_user(res : String) : String
      @nodes.each { |n| return n.name if n.reads.includes?(res) || n.writes.includes?(res) }
      raise "render graph: resource '#{res}' is never used"
    end

    # Greedy pool assignment: reuse a physical texture (same size+format) whose last user ran
    # before this resource's first user; otherwise allocate a new one. → aliasing.
    private def allocate(first : Hash(String, Int32), last : Hash(String, Int32)) : Tuple(Hash(String, Int32), Array(PostTarget))
      # Physical slot bookkeeping (parallel to the created textures).
      slot_w = [] of UInt32
      slot_h = [] of UInt32
      slot_fmt = [] of LibWGPU::TextureFormat
      slot_free_at = [] of Int32 # last node index still using this slot
      assign = {} of String => Int32

      @specs.values.sort_by { |s| {first[s.name], s.name} }.each do |s|
        reuse = nil
        slot_w.each_index do |i|
          if slot_w[i] == s.w && slot_h[i] == s.h && slot_fmt[i] == s.format && slot_free_at[i] < first[s.name]
            reuse = i
            break
          end
        end
        if r = reuse
          assign[s.name] = r
          slot_free_at[r] = last[s.name]
        else
          slot_w << s.w; slot_h << s.h; slot_fmt << s.format; slot_free_at << last[s.name]
          assign[s.name] = slot_w.size - 1
        end
      end

      physicals = Array(PostTarget).new(slot_w.size) do |i|
        PostTarget.new(@gpu, slot_w[i], slot_h[i], slot_fmt[i])
      end
      {assign, physicals}
    end

    private def find_node(name : String) : GraphNode
      @nodes.find { |n| n.name == name } || raise "render graph: no node '#{name}'"
    end
  end
end

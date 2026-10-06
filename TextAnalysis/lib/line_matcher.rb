# frozen_string_literal: true

require "set"

module FileIntegrityComparator
  # Emparelhamento de linhas dentro de um bloco de mudança.
  #
  # Suporta duas estratégias:
  #
  #   :greedy     - cada delete escolhe o melhor insert disponível.
  #                 Rápido, mas não óptimo.
  #
  #   :hungarian  - atribuição de custo total mínimo (algoritmo Húngaro).
  #                 Óptimo e simétrico. Recomendado para uso forense.
  class LineMatcher
    DEFAULT_MAX_ABSOLUTE = 5
    DEFAULT_RELATIVE_RATIO = 0.30
    DEFAULT_STRATEGY = :hungarian

    STRATEGIES = %i[greedy hungarian].freeze

    attr_reader :max_absolute, :relative_ratio, :strategy

    def initialize(max_absolute: DEFAULT_MAX_ABSOLUTE,
                   relative_ratio: DEFAULT_RELATIVE_RATIO,
                   strategy: DEFAULT_STRATEGY)
      unless STRATEGIES.include?(strategy)
        raise ArgumentError, "Estratégia desconhecida: #{strategy.inspect}. " \
                             "Use uma de: #{STRATEGIES.join(", ")}"
      end

      @max_absolute = max_absolute
      @relative_ratio = relative_ratio
      @strategy = strategy
    end

    def call(deletes, inserts)
      return { modified: [], deleted: deletes, added: inserts } if deletes.empty? || inserts.empty?

      cost = build_cost_matrix(deletes, inserts)
      assignment = assign(cost, deletes.length, inserts.length)

      pairs = []

      assignment.each do |row, col|
        next if col.nil?

        line_a, original = deletes[row]
        line_b, modified = inserts[col]
        dist = cost[row][col]
        threshold = threshold_for(original, modified)

        if dist <= threshold
          pairs << [line_a, line_b, original, modified, dist, threshold]
        end
      end

      paired_deletes = pairs.map(&:first).to_set
      paired_inserts = pairs.map { |p| p[1] }.to_set

      {
        modified: pairs,
        deleted:  deletes.reject { |ln, _| paired_deletes.include?(ln) },
        added:    inserts.reject { |ln, _| paired_inserts.include?(ln) }
      }
    end

    private

    def build_cost_matrix(deletes, inserts)
      deletes.map do |_, original|
        inserts.map do |_, modified|
          Levenshtein.distance(original, modified)
        end
      end
    end

    def assign(cost, rows, cols)
      case @strategy
      when :greedy
        GreedyAssigner.new(cost, rows, cols).solve
      when :hungarian
        HungarianSolver.new(cost).solve
      else
        raise ArgumentError, "Estratégia não suportada: #{@strategy.inspect}"
      end
    end

    def threshold_for(a, b)
      max_len = [a.length, b.length].max
      relative = (max_len * @relative_ratio).ceil
      [@max_absolute, relative].min
    end
  end

  # Emparelhamento ganancioso: cada delete escolhe o insert de menor
  # custo ainda disponível. Rápido, mas não garante o óptimo global.
  class GreedyAssigner
    def initialize(cost, rows, cols)
      @cost = cost
      @rows = rows
      @cols = cols
    end

    def solve
      used = {}
      result = {}

      (0...@rows).each do |i|
        best_j = nil
        best_dist = Float::INFINITY

        (0...@cols).each do |j|
          next if used[j]

          d = @cost[i][j]
          if d < best_dist
            best_dist = d
            best_j = j
          end
        end

        if best_j
          used[best_j] = true
          result[i] = best_j
        else
          result[i] = nil
        end
      end

      result
    end
  end

  # Implementação do algoritmo Húngaro (Kuhn-Munkres) O(n³).
  # Devolve { row_index => col_index_ou_nil }.
  class HungarianSolver
    INF = Float::INFINITY

    def initialize(cost)
      @cost = cost
      @rows = cost.length
      @cols = cost[0].length
    end

    def solve
      transposed = @rows > @cols
      matrix = transposed ? @cost.transpose : @cost

      n = matrix.length
      m = matrix[0].length

      u = Array.new(n + 1, 0.0)
      v = Array.new(m + 1, 0.0)
      p = Array.new(m + 1, 0)
      way = Array.new(m + 1, 0)

      (1..n).each do |i|
        p[0] = i
        j0 = 0
        minv = Array.new(m + 1, INF)
        used = Array.new(m + 1, false)

        loop do
          used[j0] = true
          i0 = p[j0]
          delta = INF
          j1 = 0

          (1..m).each do |j|
            next if used[j]

            cur = matrix[i0 - 1][j - 1] - u[i0] - v[j]
            if cur < minv[j]
              minv[j] = cur
              way[j] = j0
            end
            if minv[j] < delta
              delta = minv[j]
              j1 = j
            end
          end

          (0..m).each do |j|
            if used[j]
              u[p[j]] += delta
              v[j] -= delta
            else
              minv[j] -= delta
            end
          end

          j0 = j1
          break if p[j0].zero?
        end

        loop do
          j1 = way[j0]
          p[j0] = p[j1]
          j0 = j1
          break if j0.zero?
        end
      end

      row_to_col = {}
      (1..m).each do |j|
        next if p[j].zero?

        row_to_col[p[j] - 1] = j - 1
      end

      if transposed
        inverted = {}
        row_to_col.each do |row, col|
          inverted[col] = row
        end
        (0...@rows).each do |r|
          inverted[r] ||= nil
        end
        inverted
      else
        (0...@rows).each do |r|
          row_to_col[r] ||= nil
        end
        row_to_col
      end
    end
  end
end
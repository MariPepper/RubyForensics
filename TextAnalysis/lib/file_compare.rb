# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "rbconfig"
require "set"

require_relative "line_matcher"

module FileIntegrityComparator
  VERSION = "0.4.0"

  FileInfo = Struct.new(
    :path, :absolute_path, :size, :mtime, :sha256,
    keyword_init: true
  )

  Difference = Struct.new(
    :type,
    :line_a,
    :line_b,
    :original,
    :modified,
    :column,
    :levenshtein,
    :threshold,
    :changes,
    keyword_init: true
  )

  Result = Struct.new(
    :file_a,
    :file_b,
    :sha256_a,
    :sha256_b,
    :identical,
    :differences,
    :generated_at,
    :tool_version,
    :ruby_version,
    :match_method,
    keyword_init: true
  )

  # Calcula o SHA-256 diretamente dos bytes do ficheiro.
  # É deliberadamente independente da codificação textual.
  class Hasher
    def self.sha256(path)
      Digest::SHA256.file(path).hexdigest
    end
  end

  class Levenshtein
    # Distância de edição entre duas strings.
    # A comparação é feita por caracteres, não por bytes.
    def self.distance(a, b)
      a = a.to_s.each_char.to_a
      b = b.to_s.each_char.to_a

      return b.length if a.empty?
      return a.length if b.empty?

      previous = (0..b.length).to_a

      a.each_with_index do |char_a, i|
        current = [i + 1]

        b.each_with_index do |char_b, j|
          insertion = current[j] + 1
          deletion = previous[j + 1] + 1
          substitution = previous[j] + (char_a == char_b ? 0 : 1)

          current << [insertion, deletion, substitution].min
        end

        previous = current
      end

      previous[-1]
    end

    def self.first_difference(a, b)
      limit = [a.length, b.length].min

      limit.times do |i|
        return i + 1 if a[i] != b[i]
      end

      return nil if a.length == b.length

      limit + 1
    end

    # Diff ao nível de caracteres, usado apenas para explicar uma
    # linha modificada. Usa LCS (SequenceDiff), não Levenshtein.
    def self.character_changes(a, b)
      ops = SequenceDiff.new(a.each_char.to_a, b.each_char.to_a).call
      position_a = 1
      position_b = 1
      changes = []

      ops.each do |op|
        case op[:type]
        when :equal
          position_a += 1
          position_b += 1
        when :delete
          changes << {
            type: "deleted",
            column: position_a,
            value: op[:value]
          }
          position_a += 1
        when :insert
          changes << {
            type: "added",
            column: position_b,
            value: op[:value]
          }
          position_b += 1
        end
      end

      changes
    end
  end

  # LCS (Longest Common Subsequence) para produzir um diff de sequência.
  # Para um projeto académico é simples de explicar e determinístico.
  class SequenceDiff
    def initialize(a, b)
      @a = a
      @b = b
    end

    def call
      table = Array.new(@a.length + 1) { Array.new(@b.length + 1, 0) }

      @a.length.downto(0) do |i|
        @b.length.downto(0) do |j|
          next if i == @a.length || j == @b.length

          table[i][j] =
            if @a[i] == @b[j]
              1 + table[i + 1][j + 1]
            else
              [table[i + 1][j], table[i][j + 1]].max
            end
        end
      end

      i = 0
      j = 0
      result = []

      while i < @a.length || j < @b.length
        if i < @a.length && j < @b.length && @a[i] == @b[j]
          result << { type: :equal, value: @a[i] }
          i += 1
          j += 1
        elsif j < @b.length && (i == @a.length || table[i][j + 1] >= table[i + 1][j])
          result << { type: :insert, value: @b[j] }
          j += 1
        else
          result << { type: :delete, value: @a[i] }
          i += 1
        end
      end

      result
    end
  end

  class Comparator
    VALID_NORMALIZATIONS = %i[nfc nfd none].freeze

    def initialize(file_a, file_b,
                   encoding: "UTF-8",
                   normalize: :nfc,
                   max_absolute: LineMatcher::DEFAULT_MAX_ABSOLUTE,
                   relative_ratio: LineMatcher::DEFAULT_RELATIVE_RATIO,
                   strategy: LineMatcher::DEFAULT_STRATEGY)
      unless VALID_NORMALIZATIONS.include?(normalize)
        raise ArgumentError,
              "Normalização desconhecida: #{normalize.inspect}. " \
              "Use uma de: #{VALID_NORMALIZATIONS.join(", ")}"
      end

      @file_a = File.expand_path(file_a)
      @file_b = File.expand_path(file_b)
      @encoding = encoding
      @normalize = normalize
      @line_matcher = LineMatcher.new(
        max_absolute: max_absolute,
        relative_ratio: relative_ratio,
        strategy: strategy
      )
    end

    def compare
      info_a = file_info(@file_a)
      info_b = file_info(@file_b)

      # O hash resolve a questão mais forte: os bytes são iguais ou não?
      identical = info_a.sha256 == info_b.sha256

      differences =
        if identical
          []
        else
          compare_text
        end

      Result.new(
        file_a: info_a,
        file_b: info_b,
        sha256_a: info_a.sha256,
        sha256_b: info_b.sha256,
        identical: identical,
        differences: differences,
        generated_at: Time.now.utc.iso8601(6),
        tool_version: VERSION,
        ruby_version: RUBY_VERSION,
        match_method: {
          algorithm: "LCS + Levenshtein (#{@line_matcher.strategy})",
          strategy: @line_matcher.strategy,
          normalization: @normalize,
          max_absolute: @line_matcher.max_absolute,
          relative_ratio: @line_matcher.relative_ratio
        }
      )
    end

    private

    def file_info(path)
      stat = File.stat(path)
      FileInfo.new(
        path: path,
        absolute_path: path,
        size: stat.size,
        mtime: stat.mtime.utc.iso8601(6),
        sha256: Hasher.sha256(path)
      )
    end

    def read_lines(path)
      content = File.binread(path)
      content = content.force_encoding(@encoding).scrub("\uFFFD")

      case @normalize
      when :nfc
        content = content.unicode_normalize(:nfc)
      when :nfd
        content = content.unicode_normalize(:nfd)
      when :none
        # não normaliza
      else
        raise ArgumentError, "Normalização desconhecida: #{@normalize.inspect}"
      end

      content.lines.map { |line| line.chomp("\n").chomp("\r") }
    end

    def compare_text
      lines_a = read_lines(@file_a)
      lines_b = read_lines(@file_b)

      line_ops = SequenceDiff.new(lines_a, lines_b).call
      differences = []

      ia = 1
      ib = 1
      k = 0

      while k < line_ops.length
        op = line_ops[k]

        if op[:type] == :equal
          ia += 1
          ib += 1
          k += 1
          next
        end

        deletes = []
        inserts = []

        while k < line_ops.length && line_ops[k][:type] != :equal
          case line_ops[k][:type]
          when :delete
            deletes << [ia, line_ops[k][:value]]
            ia += 1
          when :insert
            inserts << [ib, line_ops[k][:value]]
            ib += 1
          end
          k += 1
        end

        # Emparelhamento com a estratégia escolhida + threshold adaptativo.
        matched = @line_matcher.call(deletes, inserts)

        matched[:modified].each do |line_a, line_b, original, modified, distance, threshold|
          column = Levenshtein.first_difference(original, modified)

          differences << Difference.new(
            type: :modified,
            line_a: line_a,
            line_b: line_b,
            original: original,
            modified: modified,
            column: column,
            levenshtein: distance,
            threshold: threshold,
            changes: Levenshtein.character_changes(original, modified)
          )
        end

        matched[:deleted].each do |line_no, value|
          differences << Difference.new(
            type: :deleted,
            line_a: line_no,
            line_b: nil,
            original: value,
            modified: nil,
            column: nil,
            levenshtein: nil,
            threshold: nil,
            changes: []
          )
        end

        matched[:added].each do |line_no, value|
          differences << Difference.new(
            type: :added,
            line_a: nil,
            line_b: line_no,
            original: nil,
            modified: value,
            column: nil,
            levenshtein: nil,
            threshold: nil,
            changes: []
          )
        end
      end

      differences
    end
  end

  class Report
    def initialize(result)
      @result = result
    end

    def to_hash
      {
        tool: {
          name: "File Integrity Comparator",
          version: @result.tool_version,
          ruby_version: @result.ruby_version
        },
        generated_at: @result.generated_at,
        identical: @result.identical,
        match_method: @result.match_method,
        files: {
          a: file_hash(@result.file_a),
          b: file_hash(@result.file_b)
        },
        differences: @result.differences.map do |d|
          {
            type: d.type.to_s,
            line_a: d.line_a,
            line_b: d.line_b,
            original: d.original,
            modified: d.modified,
            column: d.column,
            levenshtein: d.levenshtein,
            threshold: d.threshold,
            changes: d.changes
          }
        end
      }
    end

    def to_json
      JSON.pretty_generate(to_hash) + "\n"
    end

    def to_text
      lines = []
      lines << "=" * 72
      lines << "RELATÓRIO DE COMPARAÇÃO DE INTEGRIDADE"
      lines << "=" * 72
      lines << ""
      lines << "Ferramenta: File Integrity Comparator #{@result.tool_version}"
      lines << "Ruby: #{@result.ruby_version}"
      lines << "Data UTC: #{@result.generated_at}"
      if @result.match_method
        lines << "Método de emparelhamento: #{@result.match_method[:algorithm]}"
        lines << "Estratégia: #{@result.match_method[:strategy]}"
        lines << "Normalização Unicode: #{@result.match_method[:normalization]}"
        lines << "Threshold: máx absoluto=#{@result.match_method[:max_absolute]}, " \
                 "relativo=#{(@result.match_method[:relative_ratio] * 100).round}%"
      end
      lines << ""
      lines << "FICHEIRO A"
      lines << "  Caminho: #{@result.file_a.absolute_path}"
      lines << "  Tamanho: #{@result.file_a.size} bytes"
      lines << "  Modificado: #{@result.file_a.mtime}"
      lines << "  SHA-256: #{@result.sha256_a}"
      lines << ""
      lines << "FICHEIRO B"
      lines << "  Caminho: #{@result.file_b.absolute_path}"
      lines << "  Tamanho: #{@result.file_b.size} bytes"
      lines << "  Modificado: #{@result.file_b.mtime}"
      lines << "  SHA-256: #{@result.sha256_b}"
      lines << ""
      lines << "RESULTADO: #{@result.identical ? "IDÊNTICOS" : "DIFERENTES"}"
      lines << ""

      if @result.identical
        lines << "Os SHA-256 coincidem; os bytes dos dois ficheiros são iguais."
      else
        lines << "Foram encontradas #{@result.differences.length} diferença(s)."
        lines << ""
        @result.differences.each_with_index do |d, index|
          lines << "-" * 72
          lines << "DIFERENÇA #{index + 1}: #{d.type.to_s.upcase}"
          lines << "-" * 72

          case d.type
          when :modified
            lines << "Linha A: #{d.line_a}"
            lines << "Linha B: #{d.line_b}"
            lines << "Coluna da primeira diferença: #{d.column || "n/a"}"
            lines << "Distância de Levenshtein: #{d.levenshtein}"
            lines << "Threshold aplicado: #{d.threshold}"
            lines << "Original:  #{d.original.inspect}"
            lines << "Alterado:  #{d.modified.inspect}"
            unless d.changes.empty?
              lines << "Alterações de caracteres:"
              d.changes.each do |change|
                lines << "  #{change[:type]} na coluna #{change[:column]}: #{change[:value].inspect}"
              end
            end
          when :deleted
            lines << "Linha A: #{d.line_a}"
            lines << "Conteúdo eliminado: #{d.original.inspect}"
          when :added
            lines << "Linha B: #{d.line_b}"
            lines << "Conteúdo acrescentado: #{d.modified.inspect}"
          end
        end
      end

      lines << ""
      lines << "=" * 72
      lines << "NOTA FORENSE"
      lines << "=" * 72
      lines << "Este relatório documenta uma comparação técnica entre dois ficheiros."
      lines << "Não determina, por si só, autenticidade jurídica, autoria ou validade da prova."
      lines << "Essas conclusões dependem da preservação da evidência, cadeia de custódia,"
      lines << "procedimentos documentados e demais requisitos forenses/jurídicos aplicáveis."
      lines << ""

      lines.join("\n") + "\n"
    end

    private

    def file_hash(info)
      {
        path: info.path,
        absolute_path: info.absolute_path,
        size: info.size,
        modified_utc: info.mtime,
        sha256: info.sha256
      }
    end
  end

  # Log de auditoria encadeado: cada evento inclui o hash do evento anterior.
  # Isto torna alterações posteriores no log detetáveis.
  class AuditLog
    def initialize(path)
      @io = File.open(path, "ab")
      @previous_hash = "0" * 64
    end

    def record(event, data)
      payload = {
        timestamp_utc: Time.now.utc.iso8601(6),
        event: event,
        data: data,
        previous_hash: @previous_hash
      }

      canonical = JSON.generate(payload)
      record_hash = Digest::SHA256.hexdigest(canonical)

      record = payload.merge(record_hash: record_hash)
      @io.write(JSON.generate(record) + "\n")
      @io.flush
      @previous_hash = record_hash
    end

    def close
      @io.close
    end
  end
end
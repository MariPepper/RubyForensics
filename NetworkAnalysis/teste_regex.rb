linha = "11,192.168.1.10, AABBCCDDEEFF, 01/05/2024,08:15:00, DNS_OK CC=PT"
EXP_REG_PAIS = /\b(?:CC|country|pais)\s*[=:]\s*([A-Za-z]{2})\b/i
m = linha.match(EXP_REG_PAIS)
puts m ? "APANHOU: #{m[1]}" : "NAO APANHOU"
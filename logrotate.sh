#!/usr/bin/env bash
# logrotate.sh
# Script per la gestione di file di log già ruotati
# Si ispira al noto programma 'logrotate', 
# scritto da Erik Troan, Preston Brown, Jan Kaluza
# che negli anni '90 lo scrissero lavorando per RedHat
#
# Ho sentito la necessità di creare questo script 
# quando ho dovuto gestire per anni dei log creati da programmi della Suite di Oracle
# come Oracle Weblogic Server oppure Oracle HTTP Server.
# Questi programmi infatti gestiscono in autonomia la rotazione giornaliera dei
# log che generano, spesso con sequenze numeriche o timestamp,
# rendendo quindi difficile tenere traccia delle rotazioni per come sono intese da logrotate,
# forzando gli amministratori di sistema ad utilizare
# strumenti esterni come find o addirittura script custom nei blocchi di post/prerotate o lastaction.
#
# L'ispirazione a logrotate, lo confesso, e' marginale,
# e risalta soprattutto nella gestione dei pattern di ricerca.
# Infatti questo script utilizza una serie di pattern personalizzabili
# sui quali vengono effettuate le operazioni di ricerca, compressione ed eliminazione dei file.


# ======================
# --- CONFIGURAZIONE ---
# ======================
# Lista di variabili per la gestione per la personalizzazione dello script.
# Ogni variabile e' preceduta da un commento che ne esplica la funzione.

# LOG_ENABLED: Determina la creazione o meno di un file di log
# che traccia l'output dello script alla sua esecuzione. 
# true | false
LOG_ENABLED=true
# LOGFILE: indica il path assoluto o relativo nel quale verranno tracciati i log di esecuzione.
# E' possibile, se si preferisce, settare un path che includa un timestamp,
# cosi' da avere un path diverso per ogni esecuzione.
# Es: "$(dirname ""${BASH_SOURCE[0]})/custom_logrotate_script$(date +'%Y%m%d-%H%M%S')"
LOGFILE="$(dirname "${BASH_SOURCE[0]}")/custom_logrotate_script.log"
# OUTPUT_DATE_FORMAT: Determina il formato della data che verrà usato
# nell'output dello script e salvato eventualmente sul log file.
#OUTPUT_DATE_FORMAT='%Y%m%d'
OUTPUT_DATE_FORMAT='%F %T'

# MAX_KEEP_DAYS: Determina il numero di tempo in giorni da tenere come storico di log.
# In altre parole, determina la retention da tenere sui file gia' zippati
# che rientrano in uno dei pattern.
# O ancora, specifica la data di scadenza dei file compressi superata la quale i log vengono eliminati.
MAX_KEEP_DAYS=30

# MAX_AGE: Usata per determinare l'eta' minima (in secondi) per comprimere un file.
# Se un file rientra in uno dei pattern impostati, ma ha una data di modifica
# inferiore a quella di MAX_AGE non verra' compresso.
# tempo in secondi
MAX_AGE=600

# USE_TIMESTAMP_SUFFIX: Determina se il file compresso deve avere o meno un suffisso
# true | false
USE_TIMESTAMP_SUFFIX=true
# TIMESTAMP_SUFFIX_FORMAT: Configura il suffisso da usare, se abilitato,
# al termine dei file compressi.
TIMESTAMP_SUFFIX_FORMAT='%Y%m%d-%H%M%S'

# FILE_TIMESTAMP_TYPE: Variabile di carattere piu' tecnico che determina
# il tipo di timestamp che verrà utilizzato dai comandi di find per determinare
# l'ultima modifica.
# mtime | ctime | atime
FILE_TIMESTAMP_TYPE="mtime"       # Valori possibili: mtime, ctime, atime




# Inizializzazione della variabile che determina 
# se il run è dry (senza apportare modifiche) o meno.
DRY_RUN=false


# ======================================
# --- PATTERN FILE LOG DA PROCESSARE ---
# ======================================
# Lista di pattern che matchano i file che vogliamo processare.
# I file matchati dai pattern in questa lista verranno compressi
# se non aperti/blacklistati e/o modificati negli ultimi $MAX_AGE secondi.
# Verranno eliminati invece se sono compressi e sono piu' vecchi di $MAX_KEEP_DAYS.
declare -a PATTERNS=(
"/u01/app/oracle/admin/*/diagnostics/logs/OHS/*/oblog.log*"
"/u01/app/oracle/admin/*/diagnostics/logs/OHS/*/access_log*"
"/u01/app/oracle/admin/*/servers/*/logs/webgate.log*"
"/u01/app/oracle/admin/*/servers/*/logs/admin_log*"
"/u01/app/oracle/admin/*/servers/*/logs/access_log*"
"/u01/app/oracle/admin/*/diagnostics/logs/OHS/*/mod_wl_lr.log*"
"/u01/app/oracle/admin/*/diagnostics/logs/OHS/*/mod_rewrite.log*"
"/u01/wlslog/*/*/serverlogs/access.log*"
"/u01/wlslog/*/*/serverlogs/server.log*"
"/u01/wlslog/*/*/serverlogs/domain.log*"
"/u01/app/oracle/admin/*/?server/*/servers/*/logs/*.out[0-9]*[0-9]*"
"/u01/app/oracle/admin/*/?server/*/servers/*/logs/DefaultAuditRecorder.[0-9]*.log*"
"/u01/app/oracle/admin/*/?server/*/servers/*/logs/*-diagnostic-[0-9]*.log*"
"/u01/wlslog/*/*/serverlogs/verbosegc.[0-9]*[0-9].log*"
"/u01/app/oracle/admin/*/?server/*/servers/*/logs/access.log*"
"/u01/app/oracle/admin/*/?server/*/servers/*/logs/AdminServer.log*"
"/u01/app/oracle/admin/*/*/*/servers/*/logs/*.log*"
"/home/*/Downloads/*/*.sh"
"/home/*/Downloads/remotedir/bash/*/*.sh"
# aggiungi altri pattern qui per gestirli
)


# ==================
# --- BLACKLIST: ---
# ==================
# Lista di file (basename) che NON devono essere processati.
# I file che hanno i nomi inclusi in questo array non verranno compressi e/o eliminati.
declare -a BLACKLIST_FILES=(
"webgate.log"
"oblog.log"
"access_log"
"admin_log"
"AdminServer.log"
"AdminServer.out"
"nohup.out"
"access.log"
"domain.log"
"systemd.start.log"
"systemd.stop.log"
# aggiungi altri filenames qui se vuoi escludere file specifici
)

# ==========================
# --- GESTIONE ARGOMENTI ---
# ==========================
for arg in "$@"; do
	[[ "$arg" == "--dry" ]] && DRY_RUN=true
done

# =================
# --- CONTATORI ---
# =================
count_compressed=0
count_skipped_open=0
count_skipped_recent=0
count_skipped_blacklist=0
count_already_compressed=0
count_errors=0
count_deleted=0
count_delete_errors=0

# ================
# --- FUNZIONI ---
# ================

log_msg() {
	if [[ "$LOG_ENABLED" == true ]]; then 
		echo "[$(date +"$OUTPUT_DATE_FORMAT")] $1" | tee -a "$LOGFILE"
	else
		echo "[$(date +"$OUTPUT_DATE_FORMAT")] $1" 
	fi
}

is_blacklisted() {
	local filename="$1"
	for black in "${BLACKLIST_FILES[@]}"; do
		[[ "$filename" == "$black" ]] && return 0
	done
	return 1
}

compress_files() {
	local pattern="$1"
	local now timestamp suffix
	now=$(date +%s)

	files=()
	for file in $pattern; do
		if [[ -f "$file" ]]; then
			case "$file" in
				*.gz) ;;	# Skip .gz file
				*) files+=( "$file" )
			esac
		fi
	done

	if [[ ${#files[@]} -eq 0 ]]; then
		log_msg "Nessun file da processare per pattern: $pattern"
		return
	fi

	for file in "${files[@]}"; do
		[[ ! -f "$file" ]] && continue

		# Blacklist check
		if is_blacklisted "$(basename "$file")"; then
			log_msg "Skipping blacklisted file: $file"
			((count_skipped_blacklist++))
			continue
		fi

		# lsof check
		if command -v lsof &>/dev/null && lsof "$file" &>/dev/null; then
			log_msg "Skipping open file: $file"
			((count_skipped_open++))
			continue
		fi

		# Età del file (mtime/ctime/atime)
		local file_time
		case "$FILE_TIMESTAMP_TYPE" in
			mtime) file_time=$(stat -c %Y "$file") ;;
			ctime) file_time=$(stat -c %Z "$file") ;;
			atime) file_time=$(stat -c %X "$file") ;;
			*) log_msg "FILE_TIMESTAMP_TYPE non valido: $FILE_TIMESTAMP_TYPE"; exit 1 ;;
		esac
		local age=$((now - file_time))
		if (( age < MAX_AGE )); then
			log_msg "Skipping recent file (age ${age}s < ${MAX_AGE}s): $file"
			((count_skipped_recent++))
			continue
		fi

		# Compressione
		if [[ "$USE_TIMESTAMP_SUFFIX" == true ]]; then
			timestamp=$(date +"$TIMESTAMP_SUFFIX_FORMAT")
			suffix=".$timestamp.gz"
		else
			suffix=".gz"
		fi
		local gzfile="${file}${suffix}"

		if [[ -f "$gzfile" ]]; then
			log_msg "File già compresso: $gzfile"
			((count_already_compressed++))
			continue
		fi

		if [[ "$DRY_RUN" == true ]]; then
			log_msg "[DRY-RUN] Comprimerò: $file -> $gzfile"
			((count_compressed++))
		else
			if gzip --suffix="$suffix" "$file"; then
				log_msg "Compresso: $file -> $gzfile"
				((count_compressed++))
			else
				log_msg "Errore compressione: $file"
				((count_errors++))
			fi
		fi
	done
}

cleanup_old_compressed_files() {
	local pattern="$1"
	local dirpattern
	log_msg "Pulizia file compressi più vecchi di $MAX_KEEP_DAYS giorni per pattern: $pattern"

	dirpattern=$(dirname "$pattern")
	dirs=()
	for dir in $dirpattern; do
		if [[ -d "$dir" ]]; then
			dirs+=( "$dir" )
		fi
	done
	local base
	base=$(basename "$pattern")

	for dir in "${dirs[@]}"; do
		old_files=()
		while IFS= read -r line; do
			old_files+=( "$line" )
		done < <(find "$dir" -type f -name "$base" -$FILE_TIMESTAMP_TYPE +$MAX_KEEP_DAYS 2>/dev/null)
		for file in "${old_files[@]}"; do
			if [[ "$DRY_RUN" == true ]]; then
				log_msg "[DRY-RUN] Eliminerei: $file"
				((count_deleted++))
			else
				if rm -f "$file"; then
					log_msg "Eliminato: $file"
					((count_deleted++))
				else
					log_msg "Errore eliminazione: $file"
					((count_delete_errors++))
				fi
			fi
		done
	done
}

print_summary() {
	echo -e "\n[SUMMARY] Compressione:"
	printf "  Compressed:         %d\n" "$count_compressed"
	printf "  Already compressed: %d\n" "$count_already_compressed"
	printf "  Skipped open:       %d\n" "$count_skipped_open"
	printf "  Skipped recent:     %d\n" "$count_skipped_recent"
	printf "  Skipped blacklist:  %d\n" "$count_skipped_blacklist"
	printf "  Errors:             %d\n" "$count_errors"

	echo -e "\n[SUMMARY] Cleanup:"
	printf "  Deleted:            %d\n" "$count_deleted"
	printf "  Errors:             %d\n" "$count_delete_errors"
}

# --- MAIN ---
[[ "$DRY_RUN" == true ]] && log_msg "Modalità DRY-RUN attivata: nessuna modifica sarà applicata"

for pattern in "${PATTERNS[@]}"; do
	compress_files "$pattern"
	if [[ "$USE_TIMESTAMP_SUFFIX" == true ]]; then
		cleanup_old_compressed_files "$(dirname "$pattern")/*.*.gz"
	else
		cleanup_old_compressed_files "${pattern}.gz"
	fi
done

print_summary

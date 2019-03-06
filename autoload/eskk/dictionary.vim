" vim:foldmethod=marker:fen:sw=4:sts=4
scriptencoding utf-8

" Saving 'cpoptions' {{{
let s:save_cpo = &cpo
set cpo&vim
" }}}



" Utility functions {{{

" Returns [key, okuri_rom, candidates] which line contains.
function! eskk#dictionary#parse_skk_dict_line(line, from_type) abort "{{{
    let list = split(a:line, '/')
    call eskk#util#assert(
                \   !empty(list),
                \   'list must not be empty. (a:line = '
                \   .string(a:line).')')
    if list[0] =~# '^[[:alpha:]]\+'
        let key = substitute(list[0], '\s\+$', '', '')
        let okuri_rom = ''
    else
        let key = matchstr(list[0], '^[^a-z ]\+')
        let okuri_rom = matchstr(list[0], '[a-z]\+')
    endif

    let candidates = []
    for _ in list[1:]
        let semicolon = stridx(_, ';')
        if semicolon != -1
            let c = s:candidate_new(
                        \   a:from_type,
                        \   _[: semicolon - 1],
                        \   key,
                        \   '',
                        \   okuri_rom,
                        \   _[semicolon + 1 :]
                        \)
        else
            let c = s:candidate_new(
                        \   a:from_type,
                        \   _,
                        \   key,
                        \   '',
                        \   okuri_rom,
                        \   ''
                        \)
        endif
        call add(candidates, c)
    endfor

    return candidates
endfunction "}}}

" Returns line (String) which includes a:candidate.
" If invalid arguments were given, returns empty string.
function! s:insert_candidate_to_line(line, candidate) abort "{{{
    if a:line =~# '^\s*;'
        return ''
    endif
    let candidates =
                \   eskk#dictionary#parse_skk_dict_line(
                \       a:line, a:candidate.from_type)
    call insert(candidates, a:candidate)
    let candidates = eskk#util#uniq_by(
                \   candidates, 'eskk#dictionary#_candidate_identifier(v:val)')
    return s:make_line_from_candidates(candidates)
endfunction "}}}

" Returns line (String) which DOES NOT includes a:candidate.
" If invalid arguments were given, returns empty string.
function! s:delete_candidate_from_line(line, candidate) abort "{{{
    if a:line =~# '^\s*;'
        return ''
    endif

    let candidates =
                \   eskk#dictionary#parse_skk_dict_line(
                \       a:line, a:candidate.from_type)
    let not_match =
                \   '!(v:val.input ==# a:candidate.input'
                \   . '&& v:val.key ==# a:candidate.key'
                \   . '&& v:val.okuri_rom ==# a:candidate.okuri_rom)'
    call filter(candidates, not_match)
    return s:make_line_from_candidates(candidates)
endfunction "}}}
function! s:make_line_from_candidates(candidates) abort "{{{
    if type(a:candidates) isnot type([])
                \   || empty(a:candidates)
        return ''
    endif
    let c = a:candidates[0]
    let make_string =
                \   'v:val.input . '
                \   . '(v:val.annotation ==# "" ? "" : '
                \   . '";" . v:val.annotation)'
    return
                \   c.key . c.okuri_rom . ' '
                \   . '/'.join(map(copy(a:candidates), make_string), '/').'/'
endfunction "}}}


function! s:clear_command_line() abort "{{{
    redraw
    echo ''
endfunction "}}}

" }}}


" s:Candidate {{{
" One s:Candidate corresponds to SKK dictionary's one line.
" It is the pair of filtered string and its converted string.

let [
            \   s:CANDIDATE_FROM_USER_DICT,
            \   s:CANDIDATE_FROM_SYSTEM_DICT,
            \   s:CANDIDATE_FROM_REGISTERED_WORDS
            \] = range(3)

" e.g.) {key}[{okuri_rom}] /{input};{annotation}/
function! s:candidate_new(from_type, input, key, okuri, okuri_rom, annotation) abort "{{{
    return {
                \   'from_type': a:from_type,
                \   'input': a:input,
                \   'key': a:key,
                \   'okuri': a:okuri,
                \   'okuri_rom': a:okuri_rom[0],
                \   'annotation': a:annotation,
                \}
endfunction "}}}

function! eskk#dictionary#_candidate_identifier(candidate) abort "{{{
    return a:candidate.input
endfunction "}}}

" }}}


function! s:SID() abort "{{{
    return matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze_SID$')
endfunction "}}}
let s:SID_PREFIX = s:SID()
delfunc s:SID


" s:HenkanResult {{{

" This provides a way to get
" next candidate string.
" - s:HenkanResult.forward()
" - s:HenkanResult.back()
"
" self._key, self._okuri_rom, self._okuri:
"   Query for this henkan result.
"
" self._status:
"   One of g:eskk#dictionary#HR_*
"
" self._candidates:
"   Candidates looked up by
"   self._key, self._okuri_rom, self._okuri
"   NOTE: Do not access directly.
"   Getter is s:HenkanResult.get_candidates().
"
" self._candidates_index:
"   Current index of List self._candidates

let [
            \   g:eskk#dictionary#HR_NO_RESULT,
            \   g:eskk#dictionary#HR_LOOK_UP_DICTIONARY,
            \   g:eskk#dictionary#HR_GOT_RESULT
            \] = range(3)



function! s:HenkanResult_new(key, okuri_rom, okuri, preedit) abort "{{{
    let obj = deepcopy(s:HenkanResult)
    let obj = extend(obj, {
                \    'preedit': a:preedit,
                \    '_key': a:key,
                \    '_okuri_rom': a:okuri_rom[0],
                \    '_okuri': a:okuri,
                \}, 'force')
    call obj.reset()
    return obj
endfunction "}}}

" After calling this function,
" s:HenkanResult.get_candidates() will look up dictionary again.
" So call this function when you modified SKK dictionary file.
function! s:HenkanResult_reset() abort dict "{{{
    let self._status = g:eskk#dictionary#HR_LOOK_UP_DICTIONARY
    let self._candidates = eskk#util#create_data_ordered_set(
                \   {'Fn_identifier': 'eskk#dictionary#_candidate_identifier'}
                \)
    let self._candidates_index = 0
    call self.remove_cache()
endfunction "}}}

" Forward/Back self._candidates_index safely
" Returns true value when succeeded / false value when failed
function! s:HenkanResult_advance(advance) abort dict "{{{
    try
        if !self.advance_index(a:advance)
            return 0    " Can't forward/back anymore...
        endif
        call self.update_candidate_prompt()
        return 1
    catch /^eskk: dictionary look up error/
        call eskk#logger#log_exception(
                    \   's:HenkanResult.get_candidates()')
        return 0
    endtry
endfunction "}}}
" Advance self._candidates_index
function! s:HenkanResult_advance_index(advance) abort dict "{{{
    " Remove cache before changing `self` states,
    " because the cache depends on those states.
    call self.remove_cache()

    try
        let candidates = self.get_candidates()
    catch /^eskk: dictionary look up error/
        " Shut up error. This function does not throw exception.
        call eskk#logger#log_exception('s:HenkanResult.get_candidates()')
        return 0
    endtry

    let next_idx = self._candidates_index + (a:advance ? 1 : -1)
    if eskk#util#has_idx(candidates, next_idx)
        " Next time to call s:HenkanResult.get_candidates(),
        " eskk will getchar() if `next_idx >= g:eskk#show_candidates_count`
        let self._candidates_index = next_idx
        return 1
    else
        return 0
    endif
endfunction "}}}
" Set current candidate.
" but this function asks to user in command-line
" when `self._candidates_index >= g:eskk#show_candidates_count`.
" @throws eskk#dictionary#look_up_error()
function! s:HenkanResult_update_candidate_prompt() abort dict "{{{
    let max_count = g:eskk#show_candidates_count >= 0 ?
                \                   g:eskk#show_candidates_count : 0
    if self._candidates_index >= max_count
        let NONE = []
        let cand = self.select_candidate_prompt(max_count, NONE)
        if cand isnot NONE
            let [self._candidate, self._candidate_okuri] = cand
        else
            " Clear command-line.
            call s:clear_command_line()

            if self._candidates_index > 0
                " This changes self._candidates_index.
                call self.back()
            endif
            " self.get_candidates() may throw an exception.
            let candidates = self.get_candidates()
            return [
                        \   candidates[self._candidates_index].input,
                        \   self._okuri
                        \]
        endif
    else
        call self.update_candidate()
    endif
endfunction "}}}
" Set current candidate.
" @throws eskk#dictionary#look_up_error()
function! s:HenkanResult_update_candidate() abort dict "{{{
    let candidates = self.get_candidates()
    let [self._candidate, self._candidate_okuri] =
                \   [
                \       candidates[self._candidates_index].input,
                \       self._okuri
                \   ]
endfunction "}}}

" Returns List of candidates.
" @throws eskk#dictionary#look_up_error()
function! s:HenkanResult_get_candidates() abort dict "{{{
    if self._status ==# g:eskk#dictionary#HR_GOT_RESULT
        return self._candidates.to_list()

    elseif self._status ==# g:eskk#dictionary#HR_LOOK_UP_DICTIONARY
        let dict = eskk#get_skk_dict()

        " Look up from registered words.
        let registered = filter(
                    \   copy(dict.get_registered_words()),
                    \   'v:val.key ==# self._key '
                    \       . '&& v:val.okuri_rom ==# self._okuri_rom'
                    \)

        " Look up from dictionaries.
        let user_dict = dict.get_user_dict()
        let system_dict = dict.get_system_dict()
        let server_dict = dict.get_server_dict()
        let user_dict_result =
                    \   user_dict.search_candidate(
                    \       self._key, self._okuri_rom)

        let NOTFOUND = ['', -1]
        let main_dict_result = NOTFOUND
        " Look up from server and system dictionary.
        " Note: skk server does not support okuri.
        if !empty(server_dict) && server_dict.type ==# 'dictionary'
            let main_dict_result =
                        \   server_dict.search_candidate(
                        \       self._key, self._okuri_rom)
        endif
        if main_dict_result[1] ==# -1
            let main_dict_result =
                        \   system_dict.search_candidate(
                        \       self._key, self._okuri_rom)
        endif

        if user_dict_result[1] ==# -1
                    \   && main_dict_result[1] ==# -1
                    \   && empty(registered)
            let self._status = g:eskk#dictionary#HR_NO_RESULT
            throw eskk#dictionary#look_up_error(
                        \   "Can't look up '"
                        \   . g:eskk#marker_henkan
                        \   . self._key
                        \   . g:eskk#marker_okuri
                        \   . self._okuri_rom
                        \   . "' in dictionaries."
                        \)
        endif

        " NOTE: The order is important.
        " registered word, user dictionary, server, system dictionary.

        " Merge registered words.
        call self._candidates.append(registered)

        " Merge dictionaries(user, large, skkserv).
        for [result, from_type] in [
                    \   [user_dict_result, s:CANDIDATE_FROM_USER_DICT],
                    \   [main_dict_result, s:CANDIDATE_FROM_SYSTEM_DICT],
                    \]
            if result[1] !=# -1
                let candidates =
                            \   eskk#dictionary#parse_skk_dict_line(result[0], from_type)
                call eskk#util#assert(
                            \   !empty(candidates),
                            \   (result is user_dict_result ? "user" : "system")
                            \   . ' dict: `candidates` is not empty.'
                            \)
                let key = candidates[0].key
                let okuri_rom = candidates[0].okuri_rom
                call eskk#util#assert(
                            \   key ==# self._key,
                            \   (result is user_dict_result ? "user" : "system")
                            \   . " dict:".string(key)." ==# ".string(self._key)
                            \)
                call eskk#util#assert(
                            \   okuri_rom ==# self._okuri_rom[0],
                            \   (result is user_dict_result ? "user" : "system")
                            \   . " dict:".string(okuri_rom)." ==# ".string(self._okuri_rom)
                            \)

                call self._candidates.append(candidates)
            endif
        endfor

        let self._status = g:eskk#dictionary#HR_GOT_RESULT
        return self._candidates.to_list()

        " This routine makes error when using completion.
        " elseif self._status ==# g:eskk#dictionary#HR_NO_RESULT
        "     throw eskk#dictionary#look_up_error(
        "     \   "Can't look up '"
        "     \   . g:eskk#marker_henkan
        "     \   . self._key
        "     \   . g:eskk#marker_okuri
        "     \   . self._okuri_rom
        "     \   . "' in dictionaries."
        "     \)
        " else
        "     throw eskk#internal_error(['eskk', 'dictionary'])

    else
        return []
    endif
endfunction "}}}

function! eskk#dictionary#look_up_error(msg) abort "{{{
    return eskk#util#build_error(
                \   ['eskk', 'dictionary'],
                \   ['dictionary look up error', a:msg]
                \)
endfunction "}}}

" Select candidate from command-line.
" @throws eskk#dictionary#look_up_error()
function! s:HenkanResult_select_candidate_prompt(skip_num, fallback) abort dict "{{{
    " Select candidates by getchar()'s character.
    let words = copy(self.get_candidates())
    let page_index = 0
    let pages = []

    call eskk#util#assert(
                \   len(words) > a:skip_num,
                \   "words has more than skip_num words."
                \)
    let words = words[a:skip_num :]

    while !empty(words)
        let words_in_page = []
        " Add words to `words_in_page` as number of
        " string length of `g:eskk#select_cand_keys`.
        for c in split(g:eskk#select_cand_keys, '\zs')
            if empty(words)
                break
            endif
            call add(words_in_page, [c, remove(words, 0)])
        endfor
        call add(pages, words_in_page)
    endwhile

    while 1
        " Show candidates.
        redraw
        for [c, word] in pages[page_index]
            if g:eskk#show_annotation
                echon printf('%s:%s%s  ', c, word.input,
                            \       (get(word, 'annotation', '') !=# '' ?
                            \           ';' . word.annotation : ''))
            else
                echon printf('%s:%s  ', c, word.input)
            endif
        endfor
        echon printf('(%d/%d)', page_index, len(pages) - 1)

        " Get char for selected candidate.
        try
            let char = eskk#util#getchar()
        catch /^Vim:Interrupt$/
            return a:fallback
        endtry


        if char ==# "\<C-g>"
            return a:fallback
        elseif char ==# ' '
            if eskk#util#has_idx(pages, page_index + 1)
                let page_index += 1
            else
                " No more pages. Register new word.
                let dict = eskk#get_skk_dict()
                let input = dict.remember_word_prompt_hr(self)[0]
                let henkan_buf_str = self.preedit.get_buf_str(
                            \   g:eskk#preedit#PHASE_HENKAN
                            \)
                let okuri_buf_str = self.preedit.get_buf_str(
                            \   g:eskk#preedit#PHASE_OKURI
                            \)
                return [
                            \   (input !=# '' ?
                            \       input : henkan_buf_str.rom_pairs.get_filter()),
                            \   okuri_buf_str.rom_pairs.get_filter()
                            \]
            endif
        elseif char ==# 'x'
            if eskk#util#has_idx(pages, page_index - 1)
                let page_index -= 1
            else
                return a:fallback
            endif
        elseif stridx(g:eskk#select_cand_keys, char) != -1
            let selected = g:eskk#select_cand_keys[
                        \   stridx(g:eskk#select_cand_keys, char)
                        \]
            for idx in range(len(pages[page_index]))
                let [c, word] = pages[page_index][idx]
                if c ==# selected
                    " Dummy result list for `word`.
                    " Note that assigning to index number is useless.
                    let self._candidates_index = idx + a:skip_num
                    return [word.input, self._okuri]
                endif
            endfor
        endif
    endwhile
endfunction "}}}

" Clear cache of current candidate.
function! s:HenkanResult_remove_cache() abort dict "{{{
    let self._candidate       = ''
    let self._candidate_okuri = ''
endfunction "}}}


" Returns candidate String.
" if optional {with_okuri} arguments are supplied,
" returns candidate String with okuri.
function! s:HenkanResult_get_current_candidate(...) abort dict "{{{
    let with_okuri = a:0 ? a:1 : 1
    return self._candidate
                \   . (with_okuri ? self._candidate_okuri : '')
endfunction "}}}
" Getter for self._key
function! s:HenkanResult_get_key() abort dict "{{{
    return self._key
endfunction "}}}
" Getter for self._okuri
function! s:HenkanResult_get_okuri() abort dict "{{{
    return self._okuri
endfunction "}}}
" Getter for self._okuri_rom
function! s:HenkanResult_get_okuri_rom() abort dict "{{{
    return self._okuri_rom
endfunction "}}}
" Getter for self._status
function! s:HenkanResult_get_status() abort dict "{{{
    return self._status
endfunction "}}}

" Forward current candidate index number (self._candidates_index)
function! s:HenkanResult_forward() abort dict "{{{
    return self.advance(1)
endfunction "}}}
" Back current candidate index number (self._candidates_index)
function! s:HenkanResult_back() abort dict "{{{
    return self.advance(0)
endfunction "}}}
function! s:HenkanResult_has_next() abort dict "{{{
    try
        let candidates = self.get_candidates()
        let idx = self._candidates_index
        return eskk#util#has_idx(candidates, idx + 1)
    catch /^eskk: dictionary look up error/
        " Shut up error. This function does not throw exception.
        call eskk#logger#log_exception('s:HenkanResult.get_candidates()')
        return 0
    endtry
endfunction "}}}

" Delete current candidate from all places.
" e.g.:
" - s:Dictionary._registered_words
" - self._candidates
" - SKK dictionary
" -- User dictionary
" -- System dictionary (TODO: skk-ignore-dic-word. see #86)
function! s:HenkanResult_delete_from_dict() abort dict "{{{
    try
        return self.do_delete_from_dict()
    finally
        let dict = eskk#get_skk_dict()
        call dict.clear_henkan_result()
    endtry
endfunction "}}}
function! s:HenkanResult_do_delete_from_dict() abort dict "{{{
    " Check if `self` can get candidates.
    try
        let candidates = self.get_candidates()
    catch /^eskk: dictionary look up error/
        call eskk#logger#log_exception(
                    \   's:HenkanResult.get_candidates()')
        return 0
    endtry
    " Check invalid index.
    let candidates_index = self._candidates_index
    if !eskk#util#has_idx(candidates, candidates_index)
        return 0
    endif
    " Check that user dictionary is valid.
    let del_cand = candidates[candidates_index]
    let dict = eskk#get_skk_dict()
    if !dict.get_user_dict().is_valid()
        return 0
    endif
    " Check user input.
    let input = eskk#util#input(
                \   'Really purge? '
                \   . self._key . self._okuri_rom
                \   . ' /'
                \   . del_cand.input
                \   . (get(del_cand, 'annotation', '') !=# '' ?
                \       ';' . del_cand.annotation :
                \       '')
                \   . '/ (yes/no):'
                \)
    if input !~? '^y\%[es]$'
        return 0
    endif


    " Clear self.
    call self.reset()

    " Remove all elements matching with current candidate
    " from registered words.
    for word in dict.get_registered_words()
        call dict.remove_registered_word(word)
    endfor

    " Remove all elements matching with current candidate
    " from SKK dictionary.
    let lines = dict.get_user_dict().update_lines_copy()
    let i = 0
    let len = len(lines)
    while i < len
        " Leave comment line.
        if lines[i] =~# '^\s*;'
            let i += 1
            continue
        endif

        let lines[i] =
                    \   s:delete_candidate_from_line(lines[i], del_cand)
        if lines[i] ==# ''
            " If there is no more candidates,
            " delete the line.
            unlet lines[i]
            let len -= 1
            continue
        endif
        let i += 1
    endwhile
    try
        let user_dict = dict.get_user_dict()
        call user_dict.set_lines(lines)
    catch /^eskk: .* parse error/
        return 0
    endtry
    " Write to dictionary.
    call dict.update_dictionary(1, 0)

    return 1
endfunction "}}}

" Move this henkan result to the first of self._registered_words.
function! s:HenkanResult_update_rank() abort dict "{{{
    try
        let candidates = self.get_candidates()
    catch /^eskk: dictionary look up error/
        call eskk#logger#log_exception(
                    \   's:HenkanResult.get_candidates()')
        return
    endtry
    let candidates_index = self._candidates_index

    if !eskk#util#has_idx(candidates, candidates_index)
        return
    endif

    " Move self to the first.
    let dict = eskk#get_skk_dict()
    call dict.forget_word(candidates[candidates_index])
    call dict.remember_word(candidates[candidates_index])
endfunction "}}}


let s:HenkanResult = {
            \   'preedit': {},
            \   '_key': '',
            \   '_okuri_rom': '',
            \   '_okuri': '',
            \   '_status': -1,
            \   '_candidates': {},
            \   '_candidates_index': -1,
            \   '_candidate': '',
            \   '_candidate_okuri': '',
            \
            \   'reset': eskk#util#get_local_funcref('HenkanResult_reset', s:SID_PREFIX),
            \   'advance': eskk#util#get_local_funcref('HenkanResult_advance', s:SID_PREFIX),
            \   'advance_index': eskk#util#get_local_funcref('HenkanResult_advance_index', s:SID_PREFIX),
            \   'update_candidate': eskk#util#get_local_funcref('HenkanResult_update_candidate', s:SID_PREFIX),
            \   'update_candidate_prompt': eskk#util#get_local_funcref('HenkanResult_update_candidate_prompt', s:SID_PREFIX),
            \   'get_candidates': eskk#util#get_local_funcref('HenkanResult_get_candidates', s:SID_PREFIX),
            \   'select_candidate_prompt': eskk#util#get_local_funcref('HenkanResult_select_candidate_prompt', s:SID_PREFIX),
            \   'remove_cache': eskk#util#get_local_funcref('HenkanResult_remove_cache', s:SID_PREFIX),
            \   'get_current_candidate': eskk#util#get_local_funcref('HenkanResult_get_current_candidate', s:SID_PREFIX),
            \   'get_key': eskk#util#get_local_funcref('HenkanResult_get_key', s:SID_PREFIX),
            \   'get_okuri': eskk#util#get_local_funcref('HenkanResult_get_okuri', s:SID_PREFIX),
            \   'get_okuri_rom': eskk#util#get_local_funcref('HenkanResult_get_okuri_rom', s:SID_PREFIX),
            \   'get_status': eskk#util#get_local_funcref('HenkanResult_get_status', s:SID_PREFIX),
            \   'forward': eskk#util#get_local_funcref('HenkanResult_forward', s:SID_PREFIX),
            \   'back': eskk#util#get_local_funcref('HenkanResult_back', s:SID_PREFIX),
            \   'has_next': eskk#util#get_local_funcref('HenkanResult_has_next', s:SID_PREFIX),
            \   'delete_from_dict': eskk#util#get_local_funcref('HenkanResult_delete_from_dict', s:SID_PREFIX),
            \   'do_delete_from_dict': eskk#util#get_local_funcref('HenkanResult_do_delete_from_dict', s:SID_PREFIX),
            \   'update_rank': eskk#util#get_local_funcref('HenkanResult_update_rank', s:SID_PREFIX),
            \}

" }}}

" s:PhysicalDict {{{
"
" s:Dictionary may manipulate/abstract multiple dictionaries
" But s:PhysicalDict only manupulates one dictionary.
"
" _content_lines:
"   Whole lines of dictionary file.
"   Use `s:PhysicalDict.update_lines()` to get this.
"   `s:PhysicalDict.update_lines()` does:
"   - Lazy file read
"   - Memoization for getting file content
"
" _ftime_at_set:
"   UNIX time number when `_content_lines` is set.
"
" okuri_ari_idx:
"   Line number of SKK dictionary
"   where ";; okuri-ari entries." found.
"
" okuri_nasi_idx:
"   Line number of SKK dictionary
"   where ";; okuri-nasi entries." found.
"
" path:
"   File path of SKK dictionary.
"
" sorted:
"   If this value is true, assume SKK dictionary is sorted.
"   Otherwise, assume SKK dictionary is not sorted.
"
" encoding:
"   Character encoding of SKK dictionary.
"
" _is_modified:
"   If this value is true, lines were changed
"   by `s:PhysicalDict.set_lines()`.
"   Otherwise, lines were not changed.


function! s:PhysicalDict_new(path, sorted, encoding) abort "{{{
    let obj = extend(
                \   deepcopy(s:PhysicalDict),
                \   {
                \       'path': a:path,
                \       'sorted': a:sorted,
                \       'encoding': a:encoding,
                \   },
                \   'force'
                \)
    call obj.update_lines()
    return obj
endfunction "}}}



" Get List of whole lines of dictionary.
function! s:PhysicalDict_get_lines() abort dict "{{{
    return self._content_lines
endfunction "}}}

function! s:PhysicalDict_get_lines_copy() abort dict "{{{
    let lines = copy(self.get_lines())
    unlockvar 1 lines
    return lines
endfunction "}}}

function! s:PhysicalDict_make_updated_lines(registered_words) abort dict "{{{
    if a:registered_words.empty()
        return self.update_lines()
    endif
    let lines = self.update_lines_copy()

    " Check if self._user_dict really does not have registered words.
    let ari_lnum = self.okuri_ari_idx + 1
    let nasi_lnum = self.okuri_nasi_idx + 1
    for word in reverse(a:registered_words.to_list())
        " Search the line which has `word`.
        let [l, index] = self.search_candidate(word.key, word.okuri_rom)
        if index >=# 0
            " If the line exists, add `word` to the line.
            call eskk#util#assert(
                        \   l !=# '',
                        \   'line must not be empty string'
                        \   . ' (index = '.index.')'
                        \)
            let lines[index] =
                        \   s:insert_candidate_to_line(l, word)
        else
            " If the line does not exists, add new line.
            let l = s:make_line_from_candidates([word])
            call eskk#util#assert(
                        \   l !=# '',
                        \   'line must not be empty string'
                        \   . ' (index = '.index.')'
                        \)
            if word.okuri_rom !=# ''
                call insert(lines, l, ari_lnum)
                let nasi_lnum += 1
            else
                call insert(lines, l, nasi_lnum)
            endif
        endif
    endfor

    return lines
endfunction "}}}

function! s:PhysicalDict_update_lines() abort dict "{{{
    if self._ftime_at_set isnot -1
                \   && self._ftime_at_set >=# getftime(self.path)
        return self._content_lines
    endif

    try
        call self.update_lines_main()
    catch /E484:/    " Can't open file
        call eskk#logger#write_error_log_file(
                    \   {}, printf("Can't read '%s'!", self.path))
    catch /^eskk: .* parse error/
        call eskk#logger#warn(
                    \   "SKK dictionary is broken, trying to fix...: " . v:exception)

        " Try :EskkFixDictionary.
        silent execute 'EskkFixDictionary!' fnameescape(self.path)

        try
            call self.update_lines_main()
        catch /E484:/    " Can't open file
            call eskk#logger#write_error_log_file(
                        \   {}, printf("Can't read '%s'!", self.path))
        catch /^eskk: .* parse error/
            " Possible bug.
            call eskk#logger#log_exception('s:PhysicalDict.update_lines()')
            let self.okuri_ari_idx = -1
            let self.okuri_nasi_idx = -1
        endtry
    endtry

    return self._content_lines
endfunction "}}}

function! s:PhysicalDict_update_lines_main() abort dict "{{{
    unlockvar 1 self._content_lines
    let self._content_lines  = readfile(self.path)
    lockvar 1 self._content_lines
    call self.parse_lines()

    let self._ftime_at_set = getftime(self.path)
endfunction "}}}

function! s:PhysicalDict_update_lines_copy() abort dict "{{{
    let lines = copy(self.update_lines())
    unlockvar 1 lines
    return lines
endfunction "}}}

" Set List of whole lines of dictionary.
function! s:PhysicalDict_set_lines(lines) abort dict "{{{
    try
        unlockvar 1 self._content_lines
        let self._content_lines  = a:lines
        lockvar 1 self._content_lines
        call self.parse_lines()
        let self._ftime_at_set = localtime()
        let self._is_modified = 1
    catch /^eskk: .* parse error/
        call eskk#logger#log_exception('s:PhysicalDict.set_lines()')
        let self.okuri_ari_idx = -1
        let self.okuri_nasi_idx = -1
    endtry
endfunction "}}}

" - Validate List of whole lines of dictionary.
" - Set self.okuri_ari_idx, self.okuri_nasi_idx.
function! s:PhysicalDict_parse_lines() abort dict "{{{
    let self.okuri_ari_idx  = index(
                \   self._content_lines,
                \   ';; okuri-ari entries.'
                \)
    if self.okuri_ari_idx <# 0
        throw eskk#dictionary#parse_error(
                    \   "invalid self.okuri_ari_idx value"
                    \)
    endif

    let self.okuri_nasi_idx = index(
                \   self._content_lines,
                \   ';; okuri-nasi entries.'
                \)
    if self.okuri_nasi_idx <# 0
        throw eskk#dictionary#parse_error(
                    \   "invalid self.okuri_nasi_idx value"
                    \)
    endif

    if self.okuri_ari_idx >= self.okuri_nasi_idx
        throw eskk#dictionary#parse_error(
                    \   "okuri-ari entries must be before okuri-nasi entries."
                    \)
    endif
endfunction "}}}

function! eskk#dictionary#parse_error(msg) abort "{{{
    return eskk#util#build_error(
                \   ['eskk', 'dictionary'],
                \   ["SKK dictionary parse error", a:msg]
                \)
endfunction "}}}

" Returns true value if "self.okuri_ari_idx" and
" "self.okuri_nasi_idx" is valid range.
function! s:PhysicalDict_is_valid() abort dict "{{{
    " Succeeded to parse SKK dictionary.
    return self.okuri_ari_idx >= 0
                \   && self.okuri_nasi_idx >= 0
endfunction "}}}

" Set false to `self._is_modified`.
function! s:PhysicalDict_clear_modified_flags() abort dict "{{{
    let self._is_modified = 0
endfunction "}}}


" Returns all lines matching the candidate.
function! s:PhysicalDict_search_all_candidates(key_filter, okuri_rom, ...) abort dict "{{{
    let limit = a:0 ? a:1 : -1    " No limit by default.
    let has_okuri = a:okuri_rom !=# ''
    let needle = a:key_filter . (has_okuri ? a:okuri_rom : '')

    " self.is_valid() loads whole lines if it does not have,
    " so `self` can check the lines.
    if !self.is_valid()
        return []
    endif

    let whole_lines = self.get_lines()
    let converted = eskk#util#iconv(needle, &l:encoding, self.encoding)
    if self.sorted
        let [_, idx] = self.search_binary(
                    \   whole_lines,
                    \   converted,
                    \   has_okuri,
                    \   100
                    \)

        if idx == -1
            return []
        endif

        " Get lines until limit.
        let begin = idx
        let i = begin + 1
        while eskk#util#has_idx(whole_lines, i)
                    \   && stridx(whole_lines[i], converted) == 0
            let i += 1
        endwhile
        let end = i - 1
        call eskk#util#assert(begin <= end, 'begin <= end')
        if limit >= 0 && begin + limit < end
            let end = begin + limit
        endif

        return map(
                    \   whole_lines[begin : end],
                    \   'eskk#util#iconv(v:val, self.encoding, &l:encoding)'
                    \)
    else
        let lines = []
        let start = 1
        while 1
            let [line, idx] = self.search_linear(
                        \   whole_lines,
                        \   converted,
                        \   has_okuri,
                        \   start
                        \)

            if idx == -1
                break
            endif

            call add(lines, line)
            let start = idx + 1
        endwhile

        return map(
                    \   lines,
                    \   'eskk#util#iconv(v:val, self.encoding, &l:encoding)'
                    \)
    endif
endfunction "}}}

" Returns [line_string, idx] matching the candidate.
function! s:PhysicalDict_search_candidate(key_filter, okuri_rom) abort dict "{{{
    let has_okuri = a:okuri_rom !=# ''
    let needle = a:key_filter . (has_okuri ? a:okuri_rom : '') . ' '

    if !self.is_valid()
        return ['', -1]
    endif

    let whole_lines = self.get_lines()
    let converted = eskk#util#iconv(needle, &l:encoding, self.encoding)
    if self.sorted
        let [line, idx] = self.search_binary(
                    \   whole_lines, converted, has_okuri, 100
                    \)
    else
        let [line, idx] = self.search_linear(
                    \   whole_lines, converted, has_okuri
                    \)
    endif
    if idx !=# -1
        return [
                    \   eskk#util#iconv(line, self.encoding, &l:encoding),
                    \   idx
                    \]
    else
        return ['', -1]
    endif
endfunction "}}}

" Returns [line_string, idx] matching the candidate.
function! s:PhysicalDict_search_binary(whole_lines, needle, has_okuri, limit) abort dict "{{{
    " Assumption: `a:needle` is encoded to dictionary file encoding.
    " NOTE: min, max, mid are index number. not lnum.

    if a:has_okuri
        let min = self.okuri_ari_idx
        let max = self.okuri_nasi_idx
    else
        let min = self.okuri_nasi_idx
        let max = len(a:whole_lines) - 1
    endif

    let prefix = (eskk#has_if_lua() ? 'lua' : 'vim')
    let [min, max] = call(printf('s:%s_search_binary%s',
                \         prefix, (a:has_okuri ? '_okuri' : '')),
                \     [a:whole_lines, a:needle, a:limit, min, max])

    " NOTE: min, max: Give index number, not lnum.
    return self.search_linear(
                \   a:whole_lines, a:needle, a:has_okuri, min, max
                \)
endfunction "}}}

" Returns [line_string, idx] matching the candidate.
function! s:PhysicalDict_search_linear(whole_lines, needle, has_okuri, ...) abort dict "{{{
    " Assumption: `a:needle` is encoded to dictionary file encoding.
    let min_which = a:has_okuri ? 'okuri_ari_idx' : 'okuri_nasi_idx'
    let min = get(a:000, 0, self[min_which])
    let max = get(a:000, 1, len(a:whole_lines) - 1)

    if min > max
        return ['', -1]
    endif
    call eskk#util#assert(min >= 0, "min is not invalid (negative) number:" . min)

    let prefix = (eskk#has_if_lua() ? 'lua' : 'vim')
    return call('s:'.prefix.'_search_linear',
                \     [a:whole_lines, a:needle, min, max])
endfunction "}}}

" vim versions
function! s:vim_search_binary_okuri(whole_lines, needle, limit, min, max) abort "{{{
    let min = a:min
    let max = a:max
    while max - min > a:limit
        let mid = (min + max) / 2
        if a:needle >=# a:whole_lines[mid]
            let max = mid
        else
            let min = mid
        endif
    endwhile
    return [min, max]
endfunction"}}}

function! s:vim_search_binary(whole_lines, needle, limit, min, max) abort "{{{
    let min = a:min
    let max = a:max
    while max - min > a:limit
        let mid = (min + max) / 2
        if a:needle >=# a:whole_lines[mid]
            let min = mid
        else
            let max = mid
        endif
    endwhile
    return [min, max]
endfunction"}}}

function! s:vim_search_linear(whole_lines, needle, min, max) abort "{{{
    let min = a:min
    let max = a:max
    while min <=# max
        if stridx(a:whole_lines[min], a:needle) == 0
            return [a:whole_lines[min], min]
        endif
        let min += 1
    endwhile
    return ['', -1]
endfunction"}}}

" if_lua versions
" @vimlint(EVL101, 1, l:min)
" @vimlint(EVL101, 1, l:max)
function! s:lua_search_binary_okuri(whole_lines, needle, limit, min, max) abort "{{{
    lua << EOF
    do
    local whole_lines = vim.eval('a:whole_lines')
    local needle = vim.eval('a:needle')
    local limit = vim.eval('a:limit+0')
    local min = vim.eval('a:min+0')
    local max = vim.eval('a:max+0')
    local loc = os.setlocale(nil, 'collate')

    os.setlocale('C', 'collate')

    while max - min > limit do
        local mid = math.floor((min + max) / 2)
        if needle >= whole_lines[mid] then
            max = mid
        else
            min = mid
        end
    end

    os.setlocale(loc, 'collate')

    vim.command('let min = ' .. min)
    vim.command('let max = ' .. max)
end
EOF
return [float2nr(min), float2nr(max)]
endfunction"}}}
" @vimlint(EVL101, 0, l:min)
" @vimlint(EVL101, 0, l:max)

" @vimlint(EVL101, 1, l:min)
" @vimlint(EVL101, 1, l:max)
function! s:lua_search_binary(whole_lines, needle, limit, min, max) abort "{{{
    lua << EOF
    do
    local whole_lines = vim.eval('a:whole_lines')
    local needle = vim.eval('a:needle')
    local limit = vim.eval('a:limit+0')
    local min = vim.eval('a:min+0')
    local max = vim.eval('a:max+0')
    local loc = os.setlocale(nil, 'collate')

    os.setlocale('C', 'collate')

    while max - min > limit do
        local mid = math.floor((min + max) / 2)
        if needle >= whole_lines[mid] then
            min = mid
        else
            max = mid
        end
    end

    os.setlocale(loc, 'collate')

    vim.command('let min = ' .. min)
    vim.command('let max = ' .. max)
end
EOF
return [float2nr(min), float2nr(max)]
endfunction"}}}
" @vimlint(EVL101, 0, l:min)
" @vimlint(EVL101, 0, l:max)

function! s:lua_search_linear(whole_lines, needle, min, max) abort "{{{
    let ret = ['', -1]

    lua << EOF
    do
    local whole_lines = vim.eval('a:whole_lines')
    local needle = vim.eval('a:needle')
    local min = vim.eval('a:min')
    local max = vim.eval('a:max')

    for i = min, max do
        if (string.find(whole_lines[i], needle, 1, true)) == 1 then
            local ret = vim.eval('ret')
            ret[0] = whole_lines[i]
            vim.command('let ret[1] = float2nr(' .. i ..')')
            break
        end
    end
end
EOF

return ret
endfunction"}}}


let s:PhysicalDict = {
            \   '_content_lines': [],
            \   '_ftime_at_set': -1,
            \   'okuri_ari_idx': -1,
            \   'okuri_nasi_idx': -1,
            \   'path': '',
            \   'sorted': 0,
            \   'encoding': '',
            \   '_is_modified': 0,
            \
            \   'get_lines': eskk#util#get_local_funcref('PhysicalDict_get_lines', s:SID_PREFIX),
            \   'get_lines_copy': eskk#util#get_local_funcref('PhysicalDict_get_lines_copy', s:SID_PREFIX),
            \   'make_updated_lines': eskk#util#get_local_funcref('PhysicalDict_make_updated_lines', s:SID_PREFIX),
            \   'update_lines': eskk#util#get_local_funcref('PhysicalDict_update_lines', s:SID_PREFIX),
            \   'update_lines_main': eskk#util#get_local_funcref('PhysicalDict_update_lines_main', s:SID_PREFIX),
            \   'update_lines_copy': eskk#util#get_local_funcref('PhysicalDict_update_lines_copy', s:SID_PREFIX),
            \   'set_lines': eskk#util#get_local_funcref('PhysicalDict_set_lines', s:SID_PREFIX),
            \   'parse_lines': eskk#util#get_local_funcref('PhysicalDict_parse_lines', s:SID_PREFIX),
            \   'is_valid': eskk#util#get_local_funcref('PhysicalDict_is_valid', s:SID_PREFIX),
            \   'clear_modified_flags': eskk#util#get_local_funcref('PhysicalDict_clear_modified_flags', s:SID_PREFIX),
            \   'search_all_candidates': eskk#util#get_local_funcref('PhysicalDict_search_all_candidates', s:SID_PREFIX),
            \   'search_candidate': eskk#util#get_local_funcref('PhysicalDict_search_candidate', s:SID_PREFIX),
            \   'search_binary': eskk#util#get_local_funcref('PhysicalDict_search_binary', s:SID_PREFIX),
            \   'search_linear': eskk#util#get_local_funcref('PhysicalDict_search_linear', s:SID_PREFIX),
            \}

" }}}

" s:ServerDict {{{
"
" host:
"   Host name/address.
"
" port:
"   Port number.
"
" encoding:
"   Character encoding of server.
"
" timeout:
"   Timeout of server connection
"
" type:
"   "dictionary" -> Use server instead of system ditionary
"   "notfound" -> Use server if not found in system ditionary
"

function! s:ServerDict_new(server) abort "{{{
    let obj = extend(deepcopy(s:ServerDict), a:server, 'force')
    call obj.init()
    return obj
endfunction "}}}



" Initialize server.
function! s:ServerDict_init() abort dict "{{{
    if has('channel')
        let self._socket = ch_open(printf("%s:%s", self.host, self.port), {'mode': 'nl', 'timeout': self.timeout})
        if ch_status(self._socket) ==# "fail"
            call eskk#logger#warn('server initialization failed.')
        endif
    else
        if !eskk#util#has_vimproc()
                    \ || !vimproc#host_exists(self.host) || self.port <= 0
            return
        endif

        try
            let self._socket = vimproc#socket_open(self.host, self.port)
        catch
            call eskk#logger#warn('server initialization failed.')
        endtry
    endif
endfunction "}}}

function! s:ServerDict_request(command, key) abort dict "{{{
    if empty(self._socket)
        return ''
    endif

    try
        let key = a:key
        if self.encoding !=# ''
            let key = iconv(key, &encoding, self.encoding)
        endif
        if has('channel')
            let result = ch_evalraw(self._socket, printf("%s%s%s%s",
                        \ a:command, key, (key[strlen(key)-1] !=# ' ' ? ' ' : ''),
                        \ self.last_cr ? "\n" : ''))
        else
            call self._socket.write(printf('%s%s%s%s',
                        \ a:command, key, (key[strlen(key)-1] != ' ' ? ' ' : ''),
                        \ self.last_cr ? "\n" : ''))
            let result = self._socket.read_line(-1, self.timeout)
        endif
        if self.encoding !=# ''
            let result = iconv(result, self.encoding, &encoding)
        endif

        if result ==# ''
            " Reset.
            if has('channel')
                call ch_evalraw(self._socket, printf('0%s',
                        \ self.last_cr ? "\n" : ''))
                call ch_close(self._socket)
            else
                call self._socket.write(printf('0%s', self.last_cr ? "\n" : ''))
                call self._socket.close()
            endif
            call self.init()
        endif
    catch
        if has('channel')
            call ch_close(self._socket)
        else
            call self._socket.close()
        endif
        return ''
    endtry

    return result ==# '' || result[0] ==# '4' ? '' : result[1:]
endfunction "}}}
function! s:ServerDict_lookup(key) abort dict "{{{
    return self.request('1', a:key)
endfunction "}}}
function! s:ServerDict_complete(key) abort dict "{{{
    return self.request('4', a:key)
endfunction "}}}
function! s:ServerDict_search_candidate(key, okuri_rom) abort dict "{{{
    let result = a:okuri_rom ==# '' ?
                \ self.lookup(a:key) : ''
    return result !=# '' ? [a:key .' ' . result, 0] : ['', -1]
endfunction "}}}

let s:ServerDict = {
            \   '_socket': {},
            \   'host': '',
            \   'port': 1178,
            \   'encoding': 'euc-jp',
            \   'timeout': 1000,
            \   'type': 'dictionary',
            \   'last_cr': 1,
            \
            \   'init': eskk#util#get_local_funcref('ServerDict_init', s:SID_PREFIX),
            \   'request': eskk#util#get_local_funcref('ServerDict_request', s:SID_PREFIX),
            \   'lookup': eskk#util#get_local_funcref('ServerDict_lookup', s:SID_PREFIX),
            \   'complete': eskk#util#get_local_funcref('ServerDict_complete', s:SID_PREFIX),
            \   'search_candidate': eskk#util#get_local_funcref('ServerDict_search_candidate', s:SID_PREFIX),
            \}

" }}}

" s:Dictionary {{{
"
" This behaves like one file dictionary.
" But it may manipulate multiple dictionaries.
"
" _user_dict:
"   User dictionary.
"
" _system_dict:
"   System dictionary.
"
" _registered_words:
"   ordered set.
"
" _current_henkan_result:
"   Current henkan result.


function! eskk#dictionary#new(...) abort "{{{
    return call(function('s:Dictionary_new'), a:000)
endfunction "}}}

function! s:Dictionary_new(...) abort "{{{
    let user_dict = get(a:000, 0, g:eskk#directory)
    let system_dict = get(a:000, 1, g:eskk#large_dictionary)
    let server_dict = get(a:000, 2, g:eskk#server)
    return extend(
                \   deepcopy(s:Dictionary),
                \   {
                \       '_user_dict': s:PhysicalDict_new(
                \           user_dict.path,
                \           user_dict.sorted,
                \           user_dict.encoding,
                \       ),
                \       '_system_dict': s:PhysicalDict_new(
                \           system_dict.path,
                \           system_dict.sorted,
                \           system_dict.encoding,
                \       ),
                \       '_server_dict': (!empty(g:eskk#server) ?
                \                           s:ServerDict_new(server_dict) : {}),
                \       '_registered_words': eskk#util#create_data_ordered_set(
                \           {'Fn_identifier':
                \               'eskk#dictionary#_candidate_identifier'}
                \       ),
                \   },
                \   'force'
                \)
endfunction "}}}


" Find matching candidates from all places.
"
" This actually just sets "self._current_henkan_result"
" which is "s:HenkanResult"'s instance.
" This is interface so s:HenkanResult is implementation.
function! s:Dictionary_refer(preedit, key, okuri, okuri_rom) abort dict "{{{
    let hr = s:HenkanResult_new(
                \   a:key,
                \   a:okuri_rom,
                \   a:okuri,
                \   deepcopy(a:preedit, 1),
                \)
    let self._current_henkan_result = hr
    " s:HenkanResult.update_candidates() may throw
    " eskk#dictionary#look_up_error() exception.
    call hr.update_candidate()
    " Newly read lines or update lines
    " if SKK dictionary is updated.
    call self._user_dict.update_lines()
    return hr
endfunction "}}}

" Register new word (registered word) at command-line.
function! s:Dictionary_remember_word_prompt_hr(henkan_result) abort dict "{{{
    let unused = ''
    let word = s:candidate_new(
                \   unused,
                \   unused,
                \   a:henkan_result.get_key(),
                \   a:henkan_result.get_okuri(),
                \   a:henkan_result.get_okuri_rom(),
                \   unused,
                \)
    return self.remember_word_prompt(word)
endfunction "}}}
function! s:Dictionary_remember_word_prompt(word) abort dict "{{{
    let [key, okuri, okuri_rom] = [a:word.key, a:word.okuri, a:word.okuri_rom]

    " Save `&imsearch`.
    let save_imsearch = &l:imsearch
    let &l:imsearch = 1

    " Create new eskk instance.
    call eskk#create_new_instance()

    if okuri ==# ''
        let prompt = printf('%s ', key)
    else
        let prompt = printf('%s%s%s ', key, g:eskk#marker_okuri, okuri)
    endif
    try
        " Get input from command-line.
        redraw
        let input  = eskk#util#input(prompt)
    catch /^Vim:Interrupt$/
        let input = ''
    finally
        " Destroy current eskk instance.
        try
            call eskk#destroy_current_instance()
        catch /^eskk:/
            call eskk#log_warn('eskk#destroy_current_instance()')
        endtry

        " Enable eskk mapping if it has been disabled.
        call eskk#map#map_all_keys()

        " Restore `&imsearch`.
        let &l:imsearch = save_imsearch
    endtry


    if input !=# ''
        if !s:check_accidental_input(input)
            return self.remember_word_prompt(a:word)
        endif
        let [input, annotation] =
                    \   matchlist(input, '^\([^;]*\)\(.*\)')[1:2]
        let annotation = substitute(annotation, '^;', '', '')
        let word = s:candidate_new(
                    \   s:CANDIDATE_FROM_REGISTERED_WORDS,
                    \   input, key, okuri, okuri_rom, annotation)
        call self.remember_word(word)
    endif

    call s:clear_command_line()
    return [input, key, okuri]
endfunction "}}}
function! s:check_accidental_input(input) abort "{{{
    if a:input !=# strtrans(a:input)
        let answer = eskk#util#input(
                    \   "'".strtrans(a:input)."' contains unprintable character."
                    \ . " Do you really want to register? (yes/no):")
        return answer =~? '^y\%[es]$'
    elseif a:input =~# '[ 　]'
        let msg = a:input =~# '^[ 　]*$' ?
                    \   'empty string was input.' :
                    \   "'".strtrans(a:input)."' contains space(s)."
        let answer = eskk#util#input(
                    \   msg . " Do you really want to register? (yes/no):")
        return answer =~? '^y\%[es]$'
    else
        return 1
    endif
endfunction "}}}

" Clear all registered words.
function! s:Dictionary_forget_all_words() abort dict "{{{
    call self._registered_words.clear()
endfunction "}}}

" Clear given registered word.
function! s:Dictionary_forget_word(word) abort dict "{{{
    call self.remove_registered_word(a:word)

    if !empty(self._current_henkan_result)
        call self._current_henkan_result.reset()
    endif
endfunction "}}}

" Add registered word.
function! s:Dictionary_remember_word(word) abort dict "{{{
    call self._registered_words.unshift(a:word)

    if self._registered_words.size() >= g:eskk#dictionary_save_count
        call self.update_dictionary(0)
    endif

    if !empty(self._current_henkan_result)
        call self._current_henkan_result.reset()
    endif
endfunction "}}}

" Get List of registered words.
function! s:Dictionary_get_registered_words() abort dict "{{{
    return self._registered_words.to_list()
endfunction "}}}

" Remove registered word matching with arguments values.
function! s:Dictionary_remove_registered_word(word) abort dict "{{{
    return self._registered_words.remove(a:word)
endfunction "}}}

" Returns true value if new registered is added
" or user dictionary's lines are
" modified by "s:PhysicalDict.set_lines()".
" If this value is false, s:Dictionary.update_dictionary() does nothing.
function! s:Dictionary_is_modified() abort dict "{{{
    " No need to check system dictionary.
    " Because it is immutable.
    return
                \   self._user_dict._is_modified
                \   || !self._registered_words.empty()
endfunction "}}}

" Write to user dictionary.
" By default, This function is executed at VimLeavePre.
function! s:Dictionary_update_dictionary(...) abort dict "{{{
    let verbose      = get(a:000, 0, 1)
    let do_update_lines = get(a:000, 1, 1)
    if !self.is_modified()
        return
    endif
    " Invalid data.
    if filereadable(self._user_dict.path)
                \   && !self._user_dict.is_valid()
        return
    endif
    if !filereadable(self._user_dict.path)
        " Create new lines.
        " NOTE: It must not throw parse error exception!
        call self._user_dict.set_lines([
                    \   ';; okuri-ari entries.',
                    \   ';; okuri-nasi entries.'
                    \])
    endif

    if do_update_lines
        call self._user_dict.update_lines()
    endif
    call self.write_lines(
                \   self._user_dict.make_updated_lines(
                \       self._registered_words
                \   ),
                \   verbose
                \)
    call self.forget_all_words()
    call self._user_dict.clear_modified_flags()
    " Load changed lines.
    call self._user_dict.update_lines()
endfunction "}}}
function! s:Dictionary_write_lines(lines, verbose) abort dict "{{{
    let lines = a:lines

    let save_msg =
                \   "Saving to '"
                \   . self._user_dict.path
                \   . "'..."

    if a:verbose
        redraw
        echo save_msg
    endif

    try
        call writefile(lines, self._user_dict.path)
        if a:verbose
            redraw
            echo save_msg . 'Done.'
        endif
    catch
        throw eskk#internal_error(
                    \   ['eskk', 'dictionary'],
                    \   "can't write to '"
                    \       . self._user_dict.path
                    \       . "'."
                    \   . " Please check permission of '"
                    \   . self._user_dict.path . "'."
                    \)
    endtry
endfunction "}}}

" Reduce the losses of creating instance.
let s:dict_search_candidates = eskk#util#create_data_ordered_set(
            \   {'Fn_identifier': 'eskk#dictionary#_candidate_identifier'}
            \)
" Search candidates matching with arguments.
" @vimlint(EVL102, 1, a:okuri)
function! s:Dictionary_search_all_candidates(key, okuri, okuri_rom) abort dict "{{{
    let key = a:key
    let okuri_rom = a:okuri_rom

    if key ==# ''
        return []
    endif

    " To unique candidates.
    let candidates = s:dict_search_candidates
    call candidates.clear()
    let max_count = g:eskk#max_candidates

    for word in self._registered_words.to_list()
        if word.key ==# key && word.okuri_rom ==# okuri_rom
            call candidates.push(word)
            if candidates.size() >= max_count
                break
            endif
        endif
    endfor

    if candidates.size() < max_count
        " User dictionary, System dictionary
        try
            for [physical_dict, from_type] in [
                        \   [self._user_dict, s:CANDIDATE_FROM_USER_DICT],
                        \   [self._system_dict, s:CANDIDATE_FROM_SYSTEM_DICT],
                        \]
                for line in physical_dict.search_all_candidates(
                            \   key, okuri_rom, max_count - candidates.size()
                            \)
                    for c in eskk#dictionary#parse_skk_dict_line(
                                \   line, from_type
                                \)
                        let c.from_type = s:CANDIDATE_FROM_REGISTERED_WORDS
                        call candidates.push(c)
                        if candidates.size() >= max_count
                            throw 'break'
                        endif
                    endfor
                endfor
            endfor
        catch /^break$/
        endtry
    endif

    return candidates.to_list()
endfunction "}}}
" @vimlint(EVL102, 0, a:okuri)


" Getter for self._current_henkan_result
function! s:Dictionary_get_henkan_result() abort dict "{{{
    return self._current_henkan_result
endfunction "}}}
" Getter for self._user_dict
function! s:Dictionary_get_user_dict() abort dict "{{{
    return self._user_dict
endfunction "}}}
" Getter for self._system_dict
function! s:Dictionary_get_system_dict() abort dict "{{{
    return self._system_dict
endfunction "}}}
" Getter for self._server_dict
function! s:Dictionary_get_server_dict() abort dict "{{{
    return self._server_dict
endfunction "}}}

" Clear self._current_henkan_result
function! s:Dictionary_clear_henkan_result() abort dict "{{{
    let self._current_henkan_result = {}
endfunction "}}}


let s:Dictionary = {
            \   '_user_dict': {},
            \   '_system_dict': {},
            \   '_registered_words': {},
            \   '_current_henkan_result': {},
            \
            \   'refer': eskk#util#get_local_funcref('Dictionary_refer', s:SID_PREFIX),
            \   'remember_word_prompt': eskk#util#get_local_funcref('Dictionary_remember_word_prompt', s:SID_PREFIX),
            \   'remember_word_prompt_hr': eskk#util#get_local_funcref('Dictionary_remember_word_prompt_hr', s:SID_PREFIX),
            \   'forget_all_words': eskk#util#get_local_funcref('Dictionary_forget_all_words', s:SID_PREFIX),
            \   'forget_word': eskk#util#get_local_funcref('Dictionary_forget_word', s:SID_PREFIX),
            \   'remember_word': eskk#util#get_local_funcref('Dictionary_remember_word', s:SID_PREFIX),
            \   'get_registered_words': eskk#util#get_local_funcref('Dictionary_get_registered_words', s:SID_PREFIX),
            \   'remove_registered_word': eskk#util#get_local_funcref('Dictionary_remove_registered_word', s:SID_PREFIX),
            \   'is_modified': eskk#util#get_local_funcref('Dictionary_is_modified', s:SID_PREFIX),
            \   'update_dictionary': eskk#util#get_local_funcref('Dictionary_update_dictionary', s:SID_PREFIX),
            \   'write_lines': eskk#util#get_local_funcref('Dictionary_write_lines', s:SID_PREFIX),
            \   'search_all_candidates': eskk#util#get_local_funcref('Dictionary_search_all_candidates', s:SID_PREFIX),
            \   'get_henkan_result': eskk#util#get_local_funcref('Dictionary_get_henkan_result', s:SID_PREFIX),
            \   'get_user_dict': eskk#util#get_local_funcref('Dictionary_get_user_dict', s:SID_PREFIX),
            \   'get_system_dict': eskk#util#get_local_funcref('Dictionary_get_system_dict', s:SID_PREFIX),
            \   'get_server_dict': eskk#util#get_local_funcref('Dictionary_get_server_dict', s:SID_PREFIX),
            \   'clear_henkan_result': eskk#util#get_local_funcref('Dictionary_clear_henkan_result', s:SID_PREFIX),
            \}

" }}}



" Restore 'cpoptions' {{{
let &cpo = s:save_cpo
" }}}

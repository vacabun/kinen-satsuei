package com.vacabun.kinensatsuei

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class NoteEditSession(val note: Note, val token: String)

@Composable
internal fun NoteEditor(
    library: KinenLibrary,
    snapshot: KinenSnapshot,
    session: NoteEditSession,
    complete: (KinenSnapshot) -> Unit
) {
    val original = session.note
    var entry by remember { mutableStateOf(original) }
    var stored by remember { mutableStateOf(original) }
    var working by remember { mutableStateOf(false) }
    var touched by remember { mutableStateOf(false) }
    var confirmingDiscard by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val dirty = entry != original
    val hadDraft = snapshot.drafts.any { it.id == entry.id }
    fun finish(action: String) {
        if (working) return
        working = true
        val candidate = entry
        val keepDraft = touched || hadDraft || dirty || candidate != stored
        scope.launch {
            try {
                val next = withContext(Dispatchers.IO) {
                    when (action) {
                        "publish" -> {
                            library.saveDraft(candidate, session.token)
                            library.publish(candidate, session.token)
                        }
                        "discard" -> library.discardDraft(candidate, session.token)
                        else -> library.closeEditor(candidate, session.token, keepDraft)
                    }
                }
                complete(next)
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                error = failure.localizedMessage ?: "无法保存笔记。"
                working = false
            }
        }
    }
    BackHandler { finish("close") }

    LaunchedEffect(entry, working) {
        val candidate = entry
        if (candidate != original) touched = true
        if (working || candidate == stored) return@LaunchedEffect
        delay(350)
        try {
            withContext(Dispatchers.IO) { library.saveDraft(candidate, session.token) }
            stored = candidate
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            error = failure.localizedMessage ?: "无法保存草稿。"
        }
    }

    Column(Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                OutlinedTextField(entry.title, { entry = entry.copy(title = it) }, Modifier.fillMaxWidth(),
                    label = { Text("标题") }, enabled = !working)
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (kind in listOf("journal", "memory", "live", "trip")) {
                        FilterChip(selected = entry.kind == kind, enabled = !working && entry.itinerary.isEmpty(),
                            onClick = {
                                val parent = snapshot.notes.firstOrNull { it.id == entry.parentId }
                                entry = entry.copy(kind = kind, endDate = if (kind == "trip") entry.endDate else null,
                                    parentId = parent?.takeIf { acceptsChild(it.kind, kind) }?.id)
                            }, label = { Text(kindLabel(kind)) })
                    }
                }
            }
            item {
                OutlinedTextField(entry.startDate, { entry = entry.copy(startDate = it) }, Modifier.fillMaxWidth(),
                    label = { Text("开始日期（YYYY-MM-DD）") }, singleLine = true, enabled = !working)
                if (entry.kind == "trip") {
                    OutlinedTextField(entry.endDate.orEmpty(), { entry = entry.copy(endDate = it.ifBlank { null }) },
                        Modifier.fillMaxWidth(), label = { Text("结束日期（选填）") }, singleLine = true, enabled = !working)
                }
            }
            val parents = snapshot.notes.filter { it.id != entry.id && acceptsChild(it.kind, entry.kind) }
            if (parents.isNotEmpty()) {
                item { Text("上级笔记", style = MaterialTheme.typography.titleSmall) }
                item {
                    FilterChip(selected = entry.parentId == null, enabled = !working,
                        onClick = { entry = entry.copy(parentId = null) }, label = { Text("独立笔记") })
                }
                items(parents, key = { "parent-" + it.id }) { parent ->
                    FilterChip(selected = entry.parentId == parent.id, enabled = !working,
                        onClick = { entry = entry.copy(parentId = parent.id) }, label = { Text(parent.title) })
                }
            }
            item {
                OutlinedTextField(entry.body, { entry = entry.copy(body = it) }, Modifier.fillMaxWidth(),
                    label = { Text("Markdown 正文") }, minLines = 5, enabled = !working)
            }
            if (snapshot.media.isNotEmpty()) item { Text("关联媒体", style = MaterialTheme.typography.titleSmall) }
            items(snapshot.media, key = { "media-" + it.id }) { medium ->
                Row {
                    Checkbox(checked = medium.id in entry.mediaIds, enabled = !working, onCheckedChange = { enabled ->
                        entry = entry.copy(mediaIds = if (enabled) (entry.mediaIds + medium.id).distinct()
                            else entry.mediaIds.filterNot { it == medium.id })
                    })
                    Text("${kindLabel(medium.kind)} · ${medium.date ?: "日期未知"}", Modifier.padding(top = 12.dp))
                }
            }
            if (error != null) item { Text(error.orEmpty(), color = MaterialTheme.colorScheme.error) }
        }
        Surface(tonalElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (hadDraft || dirty) TextButton(enabled = !working, onClick = { confirmingDiscard = true }) { Text("丢弃草稿") }
                Spacer(Modifier.weight(1f))
                OutlinedButton(enabled = !working, onClick = { finish("close") }) { Text("关闭") }
                Button(enabled = !working && entry.title.isNotBlank(), onClick = { finish("publish") }) { Text("完成") }
            }
        }
    }
    if (confirmingDiscard) {
        AlertDialog(onDismissRequest = { confirmingDiscard = false }, title = { Text("丢弃草稿？") },
            text = { Text("已经完成的笔记会保留。") },
            confirmButton = {
                TextButton(onClick = { confirmingDiscard = false; finish("discard") }) { Text("丢弃") }
            }, dismissButton = { TextButton(onClick = { confirmingDiscard = false }) { Text("取消") } })
    }
}

{% extends "base.html" %}
{% block title %}Error · {{ app_name }}{% endblock %}
{% block content %}
<div class="card"><h1>No se pudo completar la operación</h1><p>{{ message }}</p><a class="button" href="/">Volver</a></div>
{% endblock %}
